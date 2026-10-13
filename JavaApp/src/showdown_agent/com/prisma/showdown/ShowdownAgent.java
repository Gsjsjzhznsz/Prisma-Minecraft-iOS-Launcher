package com.prisma.showdown;

import java.io.File;
import java.lang.instrument.ClassFileTransformer;
import java.lang.instrument.Instrumentation;
import java.security.ProtectionDomain;
import java.util.Arrays;
import java.util.HashSet;
import java.util.Set;

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
 * Fix: rewrite the four relative-path LDC string constants in GraalShowdownService /
 * GraalShowdownUnbundler to ABSOLUTE paths anchored at -Dame.showdown.home (set by the
 * launcher to the profile game dir). Absolute paths bypass relative-resolution bases
 * entirely, so java.io extraction, NIO validation, the checkAccess jail and
 * require()/boot() all converge on the same directory regardless of cwd/user.dir state.
 *
 * Bytecode safety: each LDC (stack +1 String) is replaced by
 *   LDC "ame.showdown.home" / LDC "" / INVOKESTATIC System.getProperty(String,String)
 *   / LDC "/showdown..." / INVOKEVIRTUAL String.concat
 * which also ends one String deep -- no branches, no locals, StackMapTable untouched
 * (COMPUTE_MAXS only, same philosophy as Task258's Knot gate patch). The transformer is
 * name-gated to the two Cobblemon classes and returns null for everything else, so
 * sessions without Cobblemon are unaffected. Rewritten classes stay in memory only;
 * the mod jar on disk is never modified.
 */
public class ShowdownAgent {

    static final String HOME_PROPERTY = "ame.showdown.home";

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
        inst.addTransformer(new ShowdownTransformer(), false);
    }

    static final class ShowdownTransformer implements ClassFileTransformer {

        static final Set<String> TARGETS = new HashSet<String>(Arrays.asList(
                "com/cobblemon/mod/common/battles/runner/graal/GraalShowdownService",
                "com/cobblemon/mod/common/battles/runner/graal/GraalShowdownUnbundler"));

        public byte[] transform(ClassLoader loader, String className,
                Class<?> classBeingRedefined, ProtectionDomain protectionDomain,
                byte[] classfileBuffer) {
            if (className == null || !TARGETS.contains(className)) {
                return null;
            }
            try {
                ClassReader cr = new ClassReader(classfileBuffer);
                ClassWriter cw = new ClassWriter(cr, ClassWriter.COMPUTE_MAXS);
                final int[] sites = new int[1];
                cr.accept(new ClassVisitor(Opcodes.ASM9, cw) {
                    @Override
                    public MethodVisitor visitMethod(int access, String name, String desc,
                            String signature, String[] exceptions) {
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
                }, 0);
                byte[] out = cw.toByteArray();
                System.out.println("[Task263] showdown path-fix applied to " + className
                        + " (" + sites[0] + " site" + (sites[0] == 1 ? "" : "s") + ")");
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
}
