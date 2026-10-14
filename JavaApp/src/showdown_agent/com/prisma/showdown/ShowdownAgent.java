package com.prisma.showdown;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.lang.instrument.ClassFileTransformer;
import java.lang.instrument.Instrumentation;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.security.CodeSource;
import java.security.ProtectionDomain;
import java.util.Arrays;
import java.util.HashSet;
import java.util.Set;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.jar.JarEntry;
import java.util.jar.JarFile;
import java.util.zip.ZipEntry;
import java.util.zip.ZipInputStream;

// Task263 r2：ASM 内嵌件等长重定位到 com/prisma/shaded（原 org/objectweb/asm 会被
// Fabric Loader 0.19.5 LoaderUtil.verifyClasspath 的 Knot.<clinit> 守卫以
// "duplicate ASM classes found on classpath" 拒绝启动——装机 latestlog.selfexit-
// 1013-210534 实锤；metallum_agent com/metallum/shaded/asm 同款先例）。重定位由
// scripts/task263_relocate_asm.py 等长字节替换完成（org/objectweb/asm 与
// com/prisma/shaded 同为 17 字节，class 文件结构零变动）。
import com.prisma.shaded.ClassReader;
import com.prisma.shaded.ClassVisitor;
import com.prisma.shaded.ClassWriter;
import com.prisma.shaded.MethodVisitor;
import com.prisma.shaded.Opcodes;

/**
 * Task263: in-memory path absolutizer for Cobblemon's GraalJS showdown service.
 *
 * Forensics (261/262/263 gamelog chain, 4 reproductions, hang signature identical):
 *   ShowdownThread.run() -> GraalShowdownService.openConnection() -> attemptUnbundle()
 *   (java.io File("showdown").mkdirs() + jar-resource extraction) -> createContext()
 *   -> first Context.eval triggers lazy JSRealm.addCommonJSGlobals() which validates
 *   js.commonjs-require-cwd="showdown" via getPublicTruffleFile("showdown").exists().
 *   That TruffleFile.exists() goes through Cobblemon's custom FileSystem checkAccess ->
 *   NIO UnixPath.toRealPath, whose relative resolution base is the -Duser.dir /
 *   StaticProperty base, while the Unbundler's java.io File syscalls land on the REAL
 *   process cwd. When the two bases diverge on iOS, the freshly extracted
 *   <realCwd>/showdown is invisible to the validation base -> guest Error
 *   "Invalid CommonJS root folder: showdown" -> ShowdownThread dies uncaught BEFORE
 *   latch.countDown() -> ShowdownThread.launch()'s latch.await() parks the Render
 *   thread forever -> JVM-wide stall, fps=0, no SDL window -> black screen "no output".
 *
 * r1 fix (kept): rewrite the four relative-path LDC string constants in
 * GraalShowdownService / GraalShowdownUnbundler to ABSOLUTE paths anchored at
 * -Dame.showdown.home (set by the launcher to the profile game dir).
 *
 * r2 escalation (device 8af8602 fifth repro: the r1 absolute rewrite DID apply --
 * the guest error path became /var/mobile/.../showdown -- yet the validation still
 * failed, while the desktop 1:1 replica with the real jar+agent COMPLETED under the
 * same symlink-split condition; therefore the divergence lives in the iOS JVM
 * port's IO layer itself, below every base we can anchor). Three defense lines:
 *
 *   D1 checkAccess neutralization: GraalShowdownService$createContext$1.checkAccess
 *      (the jail that throws IOException for any path whose toRealPath leaves wd or
 *      does not exist) is rewritten to a plain RETURN. TruffleFile.exists() is
 *      implemented as checkAccess(EMPTY)==no-IOException (truffle-api 22.3.0
 *      TruffleFile.checkAccess catches IOException -> false), so with the jail gone
 *      the CommonJS root validation can no longer reject the session on realpath
 *      quirks. Security note: the jail only guards "hacked JS files in datapacks";
 *      on the iOS sandbox the guest JS can only touch the app's own container
 *      anyway (same tradeoff JavaUWP's CobblemonShowdownFileSystemMixin made).
 *
 *   D2 dual-layer provisioning: at transform time of the Cobblemon classes (before
 *      attemptUnbundle ever runs) the agent extracts data/cobblemon/showdown.json +
 *      showdown.zip from the mod jar (located via ProtectionDomain CodeSource) into
 *      <home>/showdown using JAVA.IO, then verifies the result through BOTH java.io
 *      and NIO and logs both views. Whichever layer the port resolves correctly,
 *      boot()'s java.io File("showdown/index.js").readText() finds a fully populated
 *      folder, and the Unbundler's version-check turns attemptUnbundle into a no-op.
 *
 *   D3 latch watchdog: a daemon thread reflects Cobblemon.INSTANCE.showdownThread's
 *      latch via the captured app classloader; if the showdown thread dies uncaught
 *      (the known failure signature) or stalls past the deadline with the latch
 *      still armed, the latch is force-released so ShowdownThread.launch() stops
 *      parking the Render thread and the game boots (Cobblemon battles degrade,
 *      boot no longer hangs forever -- same philosophy as the Task251 watchdog).
 *
 * Bytecode safety (LDC rewrite, unchanged from r1): each LDC (stack +1 String) is
 * replaced by LDC "ame.showdown.home" / LDC "" / INVOKESTATIC System.getProperty /
 * LDC "/showdown..." / INVOKEVIRTUAL String.concat which also ends one String deep
 * -- no branches, no locals, StackMapTable untouched (COMPUTE_MAXS only, same
 * philosophy as Task258's Knot gate patch). The checkAccess replacement emits a
 * fresh straight-line body (no branches -> no stack map frames needed at any class
 * file version). The transformer is name-gated to the three Cobblemon classes and
 * returns null for everything else, so sessions without Cobblemon are unaffected.
 * Rewritten classes stay in memory only; the mod jar on disk is never modified.
 */
public class ShowdownAgent {

    static final String HOME_PROPERTY = "ame.showdown.home";
    static final String JAIL_CLASS =
            "com/cobblemon/mod/common/battles/runner/graal/GraalShowdownService$createContext$1";
    static final AtomicBoolean PROVISIONED = new AtomicBoolean(false);
    /** App-side classloader captured at first transform; feeds the D3 watchdog. */
    static volatile ClassLoader capturedLoader;

    public static void premain(String args, Instrumentation inst) {
        String userDir = System.getProperty("user.dir");
        String userDirCanonical;
        try {
            // 注意：getCanonicalPath 对相对 File 先经 user.dir 属性绝对化，再 realpath——
            // 它展示的是 user.dir 属性基准（NIO/GraalJS 校验基准），不是进程真实 CWD。
            // 真实 CWD 由 ObjC 侧 [CwdAlign] Task97 的 getcwd 回读行提供，两行对照即可
            // 在装机日志上直接判定两个解析基准是否分裂（Task263 取证闭环）。
            userDirCanonical = new File(".").getCanonicalPath();
        } catch (Throwable t) {
            userDirCanonical = "<" + t.getClass().getSimpleName() + ">";
        }
        String home = System.getProperty(HOME_PROPERTY);
        System.out.println("[Task263] showdown-agent armed: user.dir=" + userDir
                + " userDirCanonical=" + userDirCanonical
                + " ame.showdown.home=" + home);
        probeViews(home, "premain");
        startLatchWatchdog();
        inst.addTransformer(new ShowdownTransformer(), false);
    }

    static final class ShowdownTransformer implements ClassFileTransformer {

        static final Set<String> REWRITE_TARGETS = new HashSet<String>(Arrays.asList(
                "com/cobblemon/mod/common/battles/runner/graal/GraalShowdownService",
                "com/cobblemon/mod/common/battles/runner/graal/GraalShowdownUnbundler"));

        public byte[] transform(ClassLoader loader, String className,
                Class<?> classBeingRedefined, ProtectionDomain protectionDomain,
                byte[] classfileBuffer) {
            if (className == null) {
                return null;
            }
            boolean rewrite = REWRITE_TARGETS.contains(className);
            boolean jail = JAIL_CLASS.equals(className);
            if (!rewrite && !jail) {
                return null;
            }
            if (capturedLoader == null && loader != null) {
                capturedLoader = loader;
            }
            if (rewrite) {
                provisionFromModJar(protectionDomain);
            }
            try {
                ClassReader cr = new ClassReader(classfileBuffer);
                ClassWriter cw = new ClassWriter(cr, ClassWriter.COMPUTE_MAXS);
                final int[] sites = new int[1];
                final boolean isJail = jail;
                cr.accept(new ClassVisitor(Opcodes.ASM9, cw) {
                    @Override
                    public MethodVisitor visitMethod(int access, String name, String desc,
                            String signature, String[] exceptions) {
                        if (isJail && "checkAccess".equals(name)
                                && "(Ljava/nio/file/Path;Ljava/util/Set;[Ljava/nio/file/LinkOption;)V".equals(desc)) {
                            // D1: 发射直连 RETURN 的新方法体，原方法体整段丢弃（visitMethod
                            // 返回 null 即 ClassReader 跳过原体）。无分支无帧，major 65 安全。
                            MethodVisitor rmv = super.visitMethod(access, name, desc, signature, exceptions);
                            rmv.visitCode();
                            rmv.visitInsn(Opcodes.RETURN);
                            rmv.visitMaxs(0, 4);
                            rmv.visitEnd();
                            System.out.println("[Task263] showdown jail neutralized: "
                                    + "checkAccess -> no-op (D1, exists() can no longer reject)");
                            return null;
                        }
                        if (!isJail) {
                            MethodVisitor mv = super.visitMethod(access, name, desc, signature, exceptions);
                            return new MethodVisitor(Opcodes.ASM9, mv) {
                                @Override
                                public void visitLdcInsn(Object cst) {
                                    String suffix = suffixFor(cst);
                                    if (suffix == null) {
                                        super.visitLdcInsn(cst);
                                        return;
                                    }
                                    super.visitLdcInsn(HOME_PROPERTY);
                                    super.visitLdcInsn("");
                                    super.visitMethodInsn(Opcodes.INVOKESTATIC, "java/lang/System",
                                            "getProperty", "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;",
                                            false);
                                    super.visitLdcInsn(suffix);
                                    super.visitMethodInsn(Opcodes.INVOKEVIRTUAL, "java/lang/String",
                                            "concat", "(Ljava/lang/String;)Ljava/lang/String;", false);
                                    sites[0]++;
                                }
                            };
                        }
                        return super.visitMethod(access, name, desc, signature, exceptions);
                    }
                }, 0);
                byte[] out = cw.toByteArray();
                System.out.println("[Task263] showdown path-fix applied to " + className
                        + " (" + (isJail ? "jail" : sites[0] + " site" + (sites[0] == 1 ? "" : "s"))
                        + ")");
                return out;
            } catch (Throwable t) {
                System.out.println("[Task263] showdown path-fix FAILED for " + className
                        + ": " + t);
                return null;
            }
        }

        /** Relative constant -> absolute suffix appended to the home dir; null = leave. */
        static String suffixFor(Object cst) {
            if (!(cst instanceof String)) {
                return null;
            }
            String v = (String) cst;
            if (v.equals("showdown") || v.equals("./showdown")) {
                return "/showdown";
            }
            if (v.equals("showdown/index.js")) {
                return "/showdown/index.js";
            }
            if (v.equals("showdown-backup")) {
                return "/showdown-backup";
            }
            return null;
        }
    }

    // ---------------- D2: dual-layer provisioning (java.io extract + NIO verify) ----------------

    private static void provisionFromModJar(ProtectionDomain pd) {
        if (!PROVISIONED.compareAndSet(false, true)) {
            return;
        }
        try {
            String home = System.getProperty(HOME_PROPERTY, "");
            if (home.length() == 0) {
                System.out.println("[Task263] provision skipped: " + HOME_PROPERTY + " empty");
                return;
            }
            File dir = new File(home, "showdown");
            File indexJs = new File(dir, "index.js");
            if (indexJs.isFile()) {
                System.out.println("[Task263] provision skipped: index.js already present (prior session)");
                probeViews(home, "provision-fastpath");
                return;
            }
            CodeSource cs = pd == null ? null : pd.getCodeSource();
            if (cs == null || cs.getLocation() == null) {
                System.out.println("[Task263] provision skipped: no CodeSource (original Unbundler will try)");
                return;
            }
            File jarFile = new File(cs.getLocation().toURI());
            if (!jarFile.isFile()) {
                System.out.println("[Task263] provision skipped: code source not a plain file: " + jarFile);
                return;
            }
            JarFile jar = new JarFile(jarFile);
            try {
                JarEntry metaEntry = jar.getJarEntry("data/cobblemon/showdown.json");
                JarEntry zipEntry = jar.getJarEntry("data/cobblemon/showdown.zip");
                if (metaEntry == null || zipEntry == null) {
                    System.out.println("[Task263] provision skipped: showdown resources not in jar "
                            + jarFile.getName() + " (original Unbundler will try)");
                    return;
                }
                long t0 = System.currentTimeMillis();
                if (!dir.isDirectory() && !dir.mkdirs()) {
                    throw new IOException("mkdirs failed: " + dir);
                }
                copyStream(jar.getInputStream(metaEntry), new File(dir, "showdown.json"));
                File zip = new File(dir, "showdown.zip");
                copyStream(jar.getInputStream(zipEntry), zip);
                unzip(zip, dir);
                zip.delete();
                long dt = System.currentTimeMillis() - t0;
                boolean ioOk = indexJs.isFile();
                System.out.println("[Task263] provision done in " + dt + "ms, bytes="
                        + zipEntry.getSize() + " java.io view: index.js "
                        + (ioOk ? "OK" : "MISSING"));
                probeViews(home, "provision-post");
            } finally {
                try { jar.close(); } catch (Throwable ignore) { }
            }
        } catch (Throwable t) {
            System.out.println("[Task263] provision FAILED (original Unbundler will retry): " + t);
        }
    }

    private static void unzip(File zip, File targetDir) throws IOException {
        String canonDir = targetDir.getCanonicalPath() + File.separator;
        InputStream in = new java.io.FileInputStream(zip);
        try {
            ZipInputStream zis = new ZipInputStream(in);
            ZipEntry e;
            byte[] buf = new byte[1 << 16];
            while ((e = zis.getNextEntry()) != null) {
                File out = new File(targetDir, e.getName());
                if (!out.getCanonicalPath().startsWith(canonDir)) {
                    throw new IOException("zip slip blocked: " + e.getName());
                }
                if (e.isDirectory()) {
                    out.mkdirs();
                    continue;
                }
                File parent = out.getParentFile();
                if (parent != null && !parent.isDirectory() && !parent.mkdirs()) {
                    throw new IOException("mkdirs failed: " + parent);
                }
                OutputStream os = new FileOutputStream(out);
                try {
                    int n;
                    while ((n = zis.read(buf)) > 0) {
                        os.write(buf, 0, n);
                    }
                } finally {
                    os.close();
                }
            }
        } finally {
            in.close();
        }
    }

    private static void copyStream(InputStream in, File out) throws IOException {
        OutputStream os = new FileOutputStream(out);
        try {
            byte[] buf = new byte[1 << 16];
            int n;
            while ((n = in.read(buf)) > 0) {
                os.write(buf, 0, n);
            }
        } finally {
            os.close();
            in.close();
        }
    }

    /**
     * IO 层探针：同一组绝对路径在 java.io 与 NIO 两层下的可见性对照。
     * 装机日志若出现 io=OK nio=MISSING（或反之）即 iOS JVM 端口双层分裂实锤，
     * 也是 D1/D2 三防线必要性的直接证据（桌面 JVM 两层恒一致）。
     */
    private static void probeViews(String home, String phase) {
        if (home == null || home.length() == 0) {
            return;
        }
        try {
            File dir = new File(home, "showdown");
            File idx = new File(dir, "index.js");
            String ioView = "dir=" + (dir.isDirectory() ? "OK" : "NO")
                    + " index.js=" + (idx.isFile() ? "OK" : "NO");
            String nioView;
            try {
                Path nioDir = Paths.get(home, "showdown");
                Path nioIdx = nioDir.resolve("index.js");
                nioView = "dir=" + (Files.isDirectory(nioDir) ? "OK" : "NO")
                        + " index.js=" + (Files.isRegularFile(nioIdx) ? "OK" : "NO")
                        + " realpath=" + safeRealPath(nioDir);
            } catch (Throwable t) {
                nioView = "<" + t.getClass().getSimpleName() + ">";
            }
            System.out.println("[Task263] io-probe[" + phase + "]: java.io " + ioView
                    + " | NIO " + nioView);
        } catch (Throwable t) {
            System.out.println("[Task263] io-probe[" + phase + "] error: " + t);
        }
    }

    private static String safeRealPath(Path p) {
        try {
            return p.toRealPath(java.nio.file.LinkOption.NOFOLLOW_LINKS).toString();
        } catch (Throwable t) {
            return "<" + t.getClass().getSimpleName() + ">";
        }
    }

    // ---------------- D3: latch watchdog ----------------

    /**
     * ShowdownThread.run 未捕获死亡（本轮装机日志签名）或长时间驻停时，Render 线程
     * 永久停在 launch() 的 latch.await()。看门狗经 transform 捕获的 app classloader
     * 反射 Cobblemon.INSTANCE.showdownThread.latch：线程已死即立刻放行（已知失败
     * 签名，秒级恢复启动），线程活着但超过 240s 仍未计数也放行（防 livelock）。
     * 正常成功路径 latch 自然归零，看门狗静默退出。
     */
    private static void startLatchWatchdog() {
        Thread wd = new Thread(new Runnable() {
            public void run() {
                try {
                    ClassLoader loader = null;
                    for (int i = 0; i < 90 && loader == null; i++) {
                        loader = capturedLoader;
                        if (loader == null) {
                            Thread.sleep(1000);
                        }
                    }
                    if (loader == null) {
                        return; // 无 Cobblemon 会话（transform 从未命中）
                    }
                    Class<?> cob;
                    try {
                        cob = Class.forName("com.cobblemon.mod.common.Cobblemon", false, loader);
                    } catch (Throwable t) {
                        return; // 非 Cobblemon 整合包
                    }
                    long deadline = System.currentTimeMillis() + 240_000L;
                    boolean seenAlive = false;
                    while (System.currentTimeMillis() < deadline) {
                        try {
                            Object instance = cob.getField("INSTANCE").get(null);
                            Object sdThread = readField(cob, instance, "showdownThread");
                            if (sdThread == null) {
                                return;
                            }
                            CountDownLatch latch = (CountDownLatch) readField(sdThread.getClass(), sdThread, "latch");
                            if (latch == null || latch.getCount() == 0) {
                                return; // 正常成功路径
                            }
                            boolean alive = ((Thread) sdThread).isAlive();
                            // ★ Task268（scan-b #1 证伪修复）：原 died 要求先观测到存活
                            // （seenAlive 门，首轮 5s 轮询前死亡不触发）；stalled 判定在
                            // while(now<deadline) 体内恒 false（死代码）= 240s 防 livelock
                            // 兜底实际不存在。died 直接取 !alive（sdThread 对象存在且
                            // 非存活 = 线程已终止）；deadline 兜底移到循环外。
                            if (!alive) {
                                latch.countDown();
                                System.out.println("[Task263] watchdog: showdown latch force-released (showdown thread died uncaught; boot continues, Cobblemon battles degraded)");
                                return;
                            }
                        } catch (Throwable t) {
                            System.out.println("[Task263] watchdog probe error (disabled): " + t);
                            return;
                        }
                        Thread.sleep(5000);
                    }
                    // ★ Task268：deadline 到点兜底（原 stalled 死代码补位）——
                    // latch 仍 armed 即放行，防 showdown 线程存活但卡死的 livelock。
                    try {
                        Object instance = cob.getField("INSTANCE").get(null);
                        Object sdThread = readField(cob, instance, "showdownThread");
                        if (sdThread != null) {
                            CountDownLatch latch = (CountDownLatch) readField(sdThread.getClass(), sdThread, "latch");
                            if (latch != null && latch.getCount() != 0) {
                                latch.countDown();
                                System.out.println("[Task263] watchdog: showdown latch force-released (stalled past deadline; boot continues, Cobblemon battles degraded)");
                            }
                        }
                    } catch (Throwable t) {
                        System.out.println("[Task263] watchdog post-deadline probe error: " + t);
                    }
                } catch (Throwable fatal) {
                    System.out.println("[Task263] watchdog fatal (disabled): " + fatal);
                }
            }
        }, "Ame263-ShowdownWatchdog");
        wd.setDaemon(true);
        wd.start();
    }

    private static Object readField(Class<?> cls, Object target, String name) throws Exception {
        java.lang.reflect.Field f = cls.getDeclaredField(name);
        f.setAccessible(true);
        return f.get(target);
    }
}
