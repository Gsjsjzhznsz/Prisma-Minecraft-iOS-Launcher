package net.kdt.pojavlaunch.uikit;

import java.io.*;
import java.lang.reflect.*;
import java.util.jar.*;
import net.kdt.pojavlaunch.utils.MCOptionUtils;
import net.kdt.pojavlaunch.*;
import org.lwjgl.glfw.*;

public class UIKit {
    public static final int ACTION_DOWN = 0;
    public static final int ACTION_UP = 1;
    public static final int ACTION_MOVE = 2;
    public static final int ACTION_MOVE_MOTION = 3;

    private static int guiScale;

    private static void patch_FlatLAF_setLinux() {
        String osName = System.getProperty("os.name");
        System.setProperty("os.name", "Linux");
        try {
            Class<?> clazz = ClassLoader.getSystemClassLoader().loadClass("com.formdev.flatlaf.util.SystemInfo");
            // trigger static init
            clazz.getField("isMacOS").get(null);
        } catch (Throwable e) {
            System.out.println("Skipped patch_FlatLAF_setLinux");
            //e.printStackTrace();
        }
        System.setProperty("os.name", osName);
    }

    public static void callback_JavaGUIViewController_launchJarFile(final String filepath, String[] args) throws Throwable {
        // Launch the JAR file
        // 用 try-with-resources 确保 JarFile 关闭，避免文件描述符泄漏
        String mainClass;
        try (JarFile jarfile = new JarFile(filepath)) {
            if (jarfile.getManifest() == null) {
                throw new IllegalArgumentException("no manifest in \"" + filepath + "\"");
            }
            mainClass = jarfile.getManifest().getMainAttributes().getValue("Main-Class");
        }
        if (mainClass == null) {
            throw new IllegalArgumentException("no main manifest attribute, in \"" + filepath + "\"");
        }

        // LabyMod Installer uses FlatLAF which has some macOS-specific codes, so we make it think it's running on Linux.
        patch_FlatLAF_setLinux();

        // 用 URLClassLoader 加载 JAR，支持 JarInJar（Forge/NeoForge 部分版本 installer 内嵌 JAR 依赖）
        // 父 ClassLoader 为系统 ClassLoader，确保 PojavLauncher/UIKit bridge 类仍可加载
        java.net.URL[] urls = new java.net.URL[]{new java.io.File(filepath).toURI().toURL()};
        // ame274：URLClassLoader 从不 close = 每次启动 installer 泄漏一个
        // 打开的 jar fd；try-with-resources 在 main 返回（或异常上抛）后关闭。
        try (java.net.URLClassLoader loader = new java.net.URLClassLoader(urls, ClassLoader.getSystemClassLoader())) {
            Class<?> clazz = loader.loadClass(mainClass);
            Method method = clazz.getMethod("main", String[].class);
            try {
                method.invoke(null, new Object[]{args});
            } catch (java.lang.reflect.InvocationTargetException ite) {
                // 解包 InvocationTargetException，暴露 installer main 方法的真实异常
                Throwable cause = ite.getCause();
                if (cause != null) {
                    throw cause;
                }
                throw ite;
            }
        }
    }

    public static void updateMCGuiScale() {
        MCOptionUtils.load();
        String str = MCOptionUtils.get("guiScale");
        // ame274：options.txt 里的坏值（手改的 "auto"/空串等）直接 NFE 上抛
        // 打断启动链；try-catch 回退 0（= 自动档，对齐 native 侧解析口径）。
        int parsedScale = 0;
        if (str != null) {
            try {
                parsedScale = Integer.parseInt(str);
            } catch (NumberFormatException e) {
                System.err.println("[UIKit] Invalid guiScale value '" + str + "' in options.txt, falling back to 0");
            }
        }
        guiScale = parsedScale;

        int scale = Math.max(Math.min(GLFW.mGLFWWindowWidth / 320, GLFW.mGLFWWindowHeight / 240), 1);
        if(scale < guiScale || guiScale == 0){
            guiScale = scale;
        }
        updateMCGuiScale(guiScale);
    }

    static {
        System.load(System.getenv("BUNDLE_PATH") + "/AngelAuraAmethyst");
    }


    // public static native void runOnUIThread(UIKitCallback callback);

    public static native void showError(String title, String message, boolean exitIfOk);

    private static native void updateMCGuiScale(int scale);
}
