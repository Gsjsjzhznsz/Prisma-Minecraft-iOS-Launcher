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

        try {
            InputStream inputStream = PatchSVC.class.getClassLoader().getResourceAsStream(patchFile);
            if (inputStream == null) {
                System.err.println("PatchSVC: ERROR - Patch file not found: " + patchFile);
                return classfileBuffer;
            }

            DataInputStream dataInputStream = new DataInputStream(inputStream);
            byte[] patched = new byte[inputStream.available()];
            dataInputStream.readFully(patched);
            dataInputStream.close();

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