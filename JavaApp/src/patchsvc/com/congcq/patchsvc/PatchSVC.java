package com.congcq.patchsvc;

import java.io.*;
import java.lang.instrument.ClassFileTransformer;
import java.lang.instrument.Instrumentation;
import java.security.ProtectionDomain;

public class PatchSVC implements ClassFileTransformer {

    private static final String[][] PATCHES = {
        {"de/maxhenkel/rnnoise4j/Denoiser", "de/maxhenkel/rnnoise4j/Denoiser.class.patch"},
        {"de/maxhenkel/opus4j/OpusDecoder", "de/maxhenkel/opus4j/OpusDecoder.class.patch"},
        {"de/maxhenkel/opus4j/OpusEncoder", "de/maxhenkel/opus4j/OpusEncoder.class.patch"},
        {"de/maxhenkel/lame4j/Mp3Decoder", "de/maxhenkel/lame4j/Mp3Decoder.class.patch"},
        {"de/maxhenkel/lame4j/Mp3Encoder", "de/maxhenkel/lame4j/Mp3Encoder.class.patch"},
        {"de/maxhenkel/speex4j/AutomaticGainControl", "de/maxhenkel/speex4j/AutomaticGainControl.class.patch"},
    };

    @Override
    public byte[] transform(ClassLoader loader, String className,
                            Class<?> classBeingRedefined,
                            ProtectionDomain protectionDomain,
                            byte[] classfileBuffer) {

        String patchFile = getPatchFile(className);
        if (patchFile == null) {
            return classfileBuffer;
        }

        System.out.println("PatchSVC: Replacing class " + className);

        // ame274：平移 PatchJNAAgent 已修契约并加强——原实现 available()+readFully
        // 裸读：available()==0 时把零字节数组当补丁返回（JVM 侧表现为
        // ClassFormatError 而非优雅回退），且异常路径流从不 close（fd 泄漏）。
        // 现改为 try-with-resources 全量读；资源缺失/零字节/读失败一律回退
        // 原类字节码（ClassFileTransformer 契约中"原样返回=不替换"，与既有
        // catch 回退语义一致，也无需依赖 null 返回语义）。
        try (InputStream inputStream = PatchSVC.class.getClassLoader().getResourceAsStream(patchFile)) {
            if (inputStream == null) {
                System.err.println("PatchSVC: ERROR - Patch file not found: " + patchFile);
                return classfileBuffer;
            }

            ByteArrayOutputStream patchBuffer = new ByteArrayOutputStream(8192);
            byte[] chunk = new byte[8192];
            int read;
            while ((read = inputStream.read(chunk)) != -1) {
                patchBuffer.write(chunk, 0, read);
            }
            byte[] patched = patchBuffer.toByteArray();
            if (patched.length == 0) {
                System.err.println("PatchSVC: ERROR - Patch file empty: " + patchFile + ", using original bytecode");
                return classfileBuffer;
            }

            System.out.println("PatchSVC: SUCCESS - Patched " + className);
            return patched;

        } catch (Exception e) {
            System.err.println("PatchSVC: ERROR - " + e.getMessage());
            e.printStackTrace();
            return classfileBuffer;
        }
    }

    private String getPatchFile(String className) {
        for (String[] patch : PATCHES) {
            if (patch[0].equals(className)) {
                return patch[1];
            }
        }
        return null;
    }

    public static void premain(String args, Instrumentation instrumentation) {
        System.out.println("PatchSVC: premain called");
        instrumentation.addTransformer(new PatchSVC());
        ame251RegisterShutdownHook();
    }

    // ========================================================================
    // ★ Task251（26.3 退出挂死双保险 · 甲路信号源）
    //
    // gamelog 定案：MC 26.3 退出 = ClientShutdownWatchdog 在 post-main 超时
    // 抛 Error → System.exit(1) → JVM shutdown hooks 阶段挂死，libc exit()
    // 永不发生（启动器侧 hooked_exit 日志零出现）。
    //
    // JVM shutdown hooks 并发起跑：本 hook 与挂死 hook 同时运行，第一时间
    // 写标记文件 $POJAV_HOME/ame251_shutdown.marker；native 侧看门狗
    // （ame251_armShutdownForceExitWatchdog，150ms 轮询）命中即 _exit(0)
    // 当场终结进程 —— 覆盖 hooks/DestroyJavaVM 任何形态的 post-main 滞留。
    //
    // 门：仅 -Dame.game.session=1（launchJVM 注入）注册；headless 安装器
    // JVM 不带该属性 = Task144 的 exit 抑制语义零回归。
    // ========================================================================
    private static void ame251RegisterShutdownHook() {
        try {
            if (!"1".equals(System.getProperty("ame.game.session"))) {
                System.out.println("[Ame251] not a game session, shutdown hook skipped");
                return;
            }
            Thread ame251_hook = new Thread(() -> {
                try {
                    String ame251_home = System.getenv("POJAV_HOME");
                    if (ame251_home == null || ame251_home.length() == 0) {
                        System.out.println("[Ame251] POJAV_HOME unset, marker skipped");
                        return;
                    }
                    // ★ Task261（⑧大型整合包"无输出"取证闭环）：JVM 退出路径
                    // （System.exit / main 返回，无论正常 quit 还是静默早退）
                    // 必然经过 shutdown hooks——在写标记前把当前 latestlog 快照
                    // 为 latestlog.selfexit-<时间戳>.txt。此前的死因证据链随
                    // latestlog 轮转（两次新启动后丢失），Task261 取证时三次
                    // 静默自灭（Task251 marker 三连）因日志轮转永久失考。
                    // 快照只增不覆盖同时间戳；保留最近 3 份，更旧的清理。
                    try {
                        java.io.File ame261_cur =
                            new java.io.File(ame251_home, "latestlog.txt");
                        if (ame261_cur.exists() && ame261_cur.length() > 0) {
                            String ame261_ts = new java.text.SimpleDateFormat(
                                "MMdd-HHmmss").format(new java.util.Date());
                            java.io.File ame261_snap = new java.io.File(ame251_home,
                                "latestlog.selfexit-" + ame261_ts + ".txt");
                            java.nio.file.Files.copy(ame261_cur.toPath(),
                                ame261_snap.toPath(),
                                java.nio.file.StandardCopyOption.REPLACE_EXISTING);
                            java.io.File ame261_homeDir = new java.io.File(ame251_home);
                            java.io.File[] ame261_old = ame261_homeDir.listFiles(
                                (d, n) -> n.startsWith("latestlog.selfexit-"));
                            if (ame261_old != null && ame261_old.length > 3) {
                                java.util.Arrays.sort(ame261_old,
                                    (a, b) -> Long.compare(a.lastModified(), b.lastModified()));
                                for (int ame261_i = 0;
                                     ame261_i < ame261_old.length - 3; ame261_i++) {
                                    ame261_old[ame261_i].delete();
                                }
                            }
                            System.out.println("[Task261] selfexit snapshot saved: "
                                + ame261_snap.getName() + " (" + ame261_cur.length() + "B)"
                                + " -- silent-exit log preserved against rotation");
                        }
                    } catch (Throwable ame261_t) {
                        System.out.println("[Task261] selfexit snapshot failed: " + ame261_t);
                    }
                    java.io.File ame251_marker =
                        new java.io.File(ame251_home, "ame251_shutdown.marker");
                    if (!ame251_marker.exists()) {
                        ame251_marker.createNewFile();
                    }
                    System.out.println("[Ame251] shutdown phase entered, marker written (native watchdog will _exit)");
                } catch (Throwable t) {
                    System.out.println("[Ame251] marker write failed: " + t);
                }
            }, "Ame251-ShutdownMarker");
            ame251_hook.setDaemon(true);
            Runtime.getRuntime().addShutdownHook(ame251_hook);
            System.out.println("[Ame251] game-session shutdown hook registered (force-exit marker -> native watchdog)");
        } catch (Throwable t) {
            System.out.println("[Ame251] shutdown hook registration failed: " + t);
        }
    }
}