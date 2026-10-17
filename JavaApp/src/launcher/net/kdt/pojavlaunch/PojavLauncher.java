package net.kdt.pojavlaunch;

import java.beans.Beans;
import java.io.*;
import java.lang.reflect.Field;
import java.util.*;
import java.util.concurrent.*;

import org.lwjgl.glfw.CallbackBridge;
import org.lwjgl.glfw.GLFW;

import net.kdt.pojavlaunch.uikit.*;
import net.kdt.pojavlaunch.utils.*;
import net.kdt.pojavlaunch.value.*;

public class PojavLauncher {

    public static void main(String[] args) throws Throwable {
        // Skip calling to com.apple.eawt.Application.nativeInitializeApplicationDelegate()
        Beans.setDesignTime(true);
        try {
            // Some places use macOS-specific code, which is unavailable on iOS
            // In this case, try to get it to use Linux-specific code instead.
            com.apple.eawt.Application.getApplication();
            Class clazz = Class.forName("com.apple.eawt.Application");
            Field field = clazz.getDeclaredField("sApplication");
            field.setAccessible(true);
            field.set(null, null);
            sun.font.FontUtilities.isLinux = true;
            System.setProperty("java.util.prefs.PreferencesFactory", "java.util.prefs.FileSystemPreferencesFactory");
        } catch (Throwable th) {
            // Not on JRE8, ignore exception
            //Tools.showError(th);
        }

        Thread.currentThread().setUncaughtExceptionHandler(new Thread.UncaughtExceptionHandler() {

            public void uncaughtException(Thread t, Throwable th) {
                th.printStackTrace();
                System.exit(1);
            }
        });

        try {
            // Try to initialize Caciocavallo17
            Class.forName("com.github.caciocavallosilano.cacio.ctc.CTCPreloadClassLoader");
        } catch (ClassNotFoundException e) {}

        if (args[0].equals("-jar")) {
            UIKit.callback_JavaGUIViewController_launchJarFile(args[1], Arrays.copyOfRange(args, 2, args.length));
        } else {
            launchMinecraft(args);
        }
    }

    public static void launchMinecraft(String[] args) throws Throwable {
        // Args for Spiral Knights
        System.setProperty("appdir", "./spiral");
        System.setProperty("resource_dir", "./spiral/rsrc");

        String sizeStr = System.getProperty("cacio.managed.screensize");
        System.setProperty("glfw.windowSize", sizeStr);
        String[] size = sizeStr.split("x");
        MCOptionUtils.load();
        // Task258（清单 4）：首次启动按所选语言设置游戏语言（FCL/PCL2CE 语义）。
        // ObjC 侧把启动器语言（general.app_language，system 时已解析为系统首选语言）
        // 经 -Dame.launcher.lang 传入；options.txt 无 lang 键（首启/新实例）时写入，
        // 用户已有的语言选择永远优先，不做覆盖。
        String ame258Lang = System.getProperty("ame.launcher.lang", "");
        if (ame258Lang.length() > 0 && MCOptionUtils.get("lang") == null) {
            MCOptionUtils.set("lang", ame258Lang);
            System.out.println("[PojavLauncher] Task258: first-launch game lang set from launcher pref: " + ame258Lang);
        }
        MCOptionUtils.set("fullscreen", "false");
        MCOptionUtils.set("overrideWidth", size[0]);
        MCOptionUtils.set("overrideHeight", size[1]);
        // Task 196（vgpu 1.8.x 方块材质损坏 + 看门狗卡死修复）：
        // 装机日志铁证（latestlog.txt，1.8.9-forge 会话）：看门狗栈反复停在
        //   GL11.glCallList ← RenderList.func_178001_a
        // 且原生崩溃栈落在 libvgpu.dylib 的 gl4es_glCallList（SIGSEGV ← ANGLE memmove）。
        // 根因：反编译 1.8.9 GameSettings（avh.class）实证 useVbo 默认 false ——
        // 1.8.x 地形渲染默认走显示列表（glCallList），实体走立即模式所以正常。
        // vgpu（gl4es 血统）的显示列表模拟在 iOS ES3 上回放捕获的顶点数据
        // 损坏：方块几何/材质错乱，回放到损坏段直接 SIGSEGV。
        // 修复：vgpu 会话强制 useVbo=true，地形改走 Task191/193 已修好的
        // VBO/EBO 路径（装机实证 step-attrs 四步探针全 0 —— 0x0502 是残留
        // 旧错误，EBO 路径本身健康）。
        // 兼容性：1.8+ 均有 useVbo 选项；1.7.10- 无此键，写入会被 MC 忽略
        // （无副作用，但 1.7.10- 的显示列表问题在 vgpu 上依然无解，需换渲染器）。
        // 时序：必须在【第一块 save()】之前插入 —— 后续 graphicsApi/lang 的
        // load() 均从磁盘重读（本值已落盘，安全存续），不会丢失。
        String ame196Renderer = System.getenv("AMETHYST_RENDERER");
        if (ame196Renderer != null && ame196Renderer.contains("vgpu")) {
            MCOptionUtils.set("useVbo", "true");
            System.out.println("[PojavLauncher] Task196 useVbo=true forced (vgpu session: "
                + ame196Renderer + ", 1.8.x display-list crash workaround)");
        }
        // 解锁帧率（关闭垂直同步 + 解除 maxFps 限制）：
        // MC 默认 enableVsync=true，会把帧率锁在屏幕刷新率（60Hz 锁 60、120Hz ProMotion 锁 120）。
        // 同时 MC 默认 maxFps=120，即使关闭 VSync 也会被 maxFps 限制。
        //
        // 当启动器偏好 video.disable_game_vsync 开启时（通过环境变量 POJAV_DISABLE_VSYNC=1 传入）：
        // 1. 强制写 enableVsync=false → MC 不再调用 glfwSwapInterval(1) 请求垂直同步
        // 2. 强制写 maxFps=260 → MC 1.16+ 的源码中 maxFps>=260 时视为"无限制"（unlimited）
        //
        // 关键修复（FPS 解锁无效问题）：
        //   之前使用 maxFps=0，但 MC 的 maxFps 有效值范围是 10-260（默认 120）。
        //   maxFps=0 不是"无限制"——MC 1.16+ 源码中 0 会被当作无效值而忽略，MC 继续使用
        //   options.txt 中的旧值或默认值 120，导致帧率被锁在 120。
        //   MC 1.16+ 源码中有一个特殊判断：if (maxFps >= 260) treat as unlimited。
        //   因此正确的"无限制"设置是 maxFps=260（或更高）。
        //
        //   对于 MC 1.8-1.15 旧版本：maxFps 选项不存在或行为不同，此设置会被忽略，
        //   帧率解锁完全依赖 native 层的 eglSwapInterval(0) 拦截。
        //
        // MC 26.2+ 兼容性（关键修复）：
        //   MC 26.2 可能重命名了选项。同时写入多种可能的选项名以确保兼容：
        //   - maxFps（MC 1.16-1.21）：帧率上限
        //   - maxFramerate（MC 26.2+ 可能的新名称）：帧率上限
        //   - enableVsync（所有版本）：垂直同步开关
        //   - framerateLimit（MC 26.2+ 可能的替代名称）：帧率限制
        //
        // 这样做的效果：
        // - Vulkan 渲染器（MoltenVK）：LWJGL 创建 swapchain 时使用 VK_PRESENT_MODE_IMMEDIATE_KHR，
        //   MoltenVK 不等待 vblank 直接 present，帧率可超过屏幕刷新率（减少输入延迟）
        // - GL 类渲染器（ANGLE Metal）：eglSwapInterval(0) 让渲染线程不阻塞，
        //   但 Core Animation 仍按屏幕刷新率合成（实际帧率不超过屏幕刷新率，但渲染线程吞吐量提高）
        //
        // 用 set（而非 setDefault）覆盖：每次启动都强制关闭，确保生效；
        // 用户若想恢复游戏内垂直同步和帧率限制，可在启动器设置关闭该开关。
        if ("1".equals(System.getenv("POJAV_DISABLE_VSYNC"))) {
            MCOptionUtils.set("enableVsync", "false");
            // maxFps=260：MC 1.16+ 源码中 maxFps>=260 视为 unlimited
            // （之前用 0 会被当作无效值忽略，导致帧率仍被 maxFps=120 限制）
            MCOptionUtils.set("maxFps", "260");
            // MC 26.2+ 兼容：可能重命名为 maxFramerate 或 framerateLimit
            MCOptionUtils.set("maxFramerate", "260");
            MCOptionUtils.set("framerateLimit", "260");
            // MC 1.21.8+ 兼容：inactivityFpsLimit 选项（InactivityFpsLimit 枚举）
            //
            // 关键修复（帧率解锁无效根因之一）：
            // MC 1.21.8+ 引入了"不活动帧率限制"功能（inactivityFpsLimit），
            // 默认值为 "afk"：
            //   - 无输入 1 分钟后帧率降至 30 FPS
            //   - 无输入 10 分钟后帧率降至 10 FPS
            //   - 窗口最小化时帧率降至 10 FPS
            // 这导致用户在 iOS 上切后台/不操作时帧率被严重限制，
            // 即使关闭了 VSync 和 maxFps 限制也无济于事。
            //
            // InactivityFpsLimit 枚举只有两个值：
            //   - "afk"（默认）：AFK 模式，不操作时限帧
            //   - "minimized"：仅最小化时限帧（10 FPS）
            //
            // 设置为 "minimized" 后，用户不操作时不会限帧，
            // 仅在窗口最小化（iOS 上几乎不会发生）时限帧。
            // 这样配合 VSync 关闭 + maxFps=260 可以真正实现帧率解锁。
            //
            // 旧版本 MC（1.21.7 及以下）不识别此选项，会被忽略，无副作用。
            MCOptionUtils.set("inactivityFpsLimit", "minimized");
            // 诊断日志：输出写入的帧率相关选项
            System.out.println("[PojavLauncher] VSync disabled, maxFps/maxFramerate/framerateLimit set to 260");
            System.out.println("[PojavLauncher]   enableVsync=" + MCOptionUtils.get("enableVsync"));
            System.out.println("[PojavLauncher]   maxFps=" + MCOptionUtils.get("maxFps"));
            System.out.println("[PojavLauncher]   maxFramerate=" + MCOptionUtils.get("maxFramerate"));
            System.out.println("[PojavLauncher]   framerateLimit=" + MCOptionUtils.get("framerateLimit"));
            System.out.println("[PojavLauncher]   inactivityFpsLimit=" + MCOptionUtils.get("inactivityFpsLimit"));
        }
        // Default settings for performance
        MCOptionUtils.setDefault("mipmapLevels", "0");
        MCOptionUtils.setDefault("particles", "1");
        MCOptionUtils.setDefault("renderDistance", "2");
        MCOptionUtils.setDefault("simulationDistance", "5");
        // 关闭 OIT（Order-Independent Transparency）—— renderpearl 的
        // oit_transmittance_flat_clouds Vulkan 管线在 MoltenVK / A11 GPU 上
        // 编译失败导致崩溃。graphicsMode 0=Fast,1=Fancy,2=Fabulous(OIT)。
        // 对齐 Ynnyny 仓库 be74cd4。
        MCOptionUtils.setDefault("graphicsMode", "0");
        MCOptionUtils.setDefault("transparency", "0");
        
        MCOptionUtils.save();

        // Task 104（26.3 30fps 取证闭环）：落盘校验。上面内存 get() 的回显
        // 只能证明内存态；这里从磁盘重读 MC 即将加载的 options.txt，下一轮
        // 装机日志即可一锤定音"写入是否真的落到了 MC 读的文件"。
        // 已知异常现场：26.3 运行期以 AFK 模式跑（SHORT_AFK=30fps 实锤），
        // 而启动器明明写了 minimized —— 分叉点就在这层。
        // ★ Task280（kw"锁30"归因收口——fps-cap posture 无条件化+verdict）：
        //   原块只在 POJAV_DISABLE_VSYNC=1 时打印——而用户关掉解锁偏好时恰是
        //   maxFps=30 存活的场景（解锁链不跑，整合包自带的 maxFps:30 原样生
        //   效），日志反而静默。kw 1.8.9 会话 RenderDiag build=33ms/pres=0 的
        //   两个候选根因（MC 内部 maxFps 上限 vs 逐 draw 转译税）从此行一锤
        //   定音：maxFps<260 → MC 内部上限在玩（fps≤maxFps 是游戏内 Max
        //   Framerate 设置的预期行为，非 bug）；maxFps≥260 → 上限不在 MC 设
        //   置，转渲染器 CPU/GPU 侧（配合 [RenderDiag] phase= 判读）。1.8 的
        //   视频设置本就有 Max Framerate（滑条 10-260，260=Unlimited），旧注释
        //   "1.8-1.15 无此键"不成立，随本块无条件化一并修正。
        String ame280MaxFps = MCOptionUtils.getFromFile("maxFps");
        String ame280Verdict;
        if (ame280MaxFps == null) {
            ame280Verdict = "no-maxFps-key(MC-internal-default) -- cap NOT from options.txt";
        } else {
            try {
                int ame280Fps = Integer.parseInt(ame280MaxFps.trim());
                ame280Verdict = (ame280Fps >= 260)
                    ? "unlimited-no-MC-cap -- fps ceiling is CPU/GPU side (see RenderDiag phase=)"
                    : "MC-INTERNAL-CAP-ACTIVE fps<=" + ame280Fps
                        + " (in-game Max Framerate setting; raise in-game to unlock)";
            } catch (NumberFormatException ame280Nfe) {
                ame280Verdict = "unparsable-maxFps(" + ame280MaxFps + ")";
            }
        }
        System.out.println("[PojavLauncher] Task280 fps-cap posture: renderer="
            + System.getenv("AMETHYST_RENDERER")
            + " vsyncEnv=" + System.getenv("POJAV_DISABLE_VSYNC")
            + " maxFps=" + ame280MaxFps
            + " enableVsync=" + MCOptionUtils.getFromFile("enableVsync")
            + " inactivityFpsLimit=" + MCOptionUtils.getFromFile("inactivityFpsLimit")
            + " verdict=" + ame280Verdict);
        // Task 196：落盘校验（必须在 save() 之后 —— getFromFile 直读磁盘，
        // save 前读到的是旧盘值）。装机日志锚点：useVbo=true。
        if (ame196Renderer != null && ame196Renderer.contains("vgpu")) {
            System.out.println("[PojavLauncher] Task196 on-disk verification: useVbo="
                + MCOptionUtils.getFromFile("useVbo"));
        }

        // 提示 renderpearl 跳过 OIT 管线编译
        System.setProperty("com.mojang.renderpearl.disableOIT", "true");
        System.setProperty("com.mojang.renderpearl.skipOIT", "true");
        System.setProperty("com.mojang.renderpearl.forceNoOIT", "true");

        // Setup Forge splash.properties
        File forgeSplashFile = new File(Tools.DIR_GAME_NEW, "config/splash.properties");
        if (System.getProperty("pojav.internal.keepForgeSplash") == null) {
            forgeSplashFile.getParentFile().mkdir();
            if (forgeSplashFile.exists()) {
                // replace 必须作用在 read() 读出的文件内容上，而非路径字符串（原写法恒 no-op，
                // 存量 enabled=true 永远关不掉，Forge 二次启动 splash 复活）。
                Tools.write(forgeSplashFile.getAbsolutePath(), Tools.read(forgeSplashFile.getAbsolutePath()).replace("enabled=true", "enabled=false"));
            } else {
                Tools.write(forgeSplashFile.getAbsolutePath(), "enabled=false");
            }
        }

        // 仅在显式选择 Vulkan 渲染器时设置 LWJGL Vulkan native 库名称，
        // 避免覆盖 JavaLauncher.m 为 ANGLE/MobileGlues/GL4ES 设置的 OpenGL libname。
        //
        // 传裸名 "MoltenVK"。LWJGL 的 Platform.mapLibraryName（macOS 分支）用正则
        //     (?:^|/)lib\w+(?:[.]\d+)*[.]dylib$
        // 判断 libname 是否已是 dylib 文件名：匹配则原样返回，否则交给
        // System.mapLibraryName 补 "lib" 前缀与 ".dylib" 后缀。
        // 裸名不以 lib 开头，必定走后者 -> "libMoltenVK.dylib"，与磁盘一致。
        //
        // 修正旧注释：它声称传 "libMoltenVK.dylib" 会被二次包装成
        // "liblibMoltenVK.dylib.dylib"。实际上该名是匹配上述正则的（\w 覆盖
        // "MoltenVK"），原样返回并不会被二次包装。真正会中招的是名字含连字符的库
        // —— "\w" 不含 '-'，例如 "libMobileGL-gles.dylib" 会被误判并包装成
        // "liblibMobileGL-gles.dylib.dylib"。统一传裸名可让规则对任何文件名都成立。
        String renderer = System.getenv("AMETHYST_RENDERER");
        if ("libMoltenVK.dylib".equals(renderer) || "vulkan".equals(renderer)) {
            System.setProperty("org.lwjgl.vulkan.libname", "MoltenVK");
        }

        // MC 26.2+ Graphics API 切换（OpenGL/Vulkan 游戏内图形后端选择）
        //
        // Mojang 在 MC 26.2 Snapshot 1 引入了 "Graphics API" 视频设置项，有 3 个值：
        //   - default        由 Mojang 决定（26.2-snapshot-1~7 为 Vulkan，snapshot-8+ 为 OpenGL）
        //   - prefer_vulkan  优先使用 Vulkan，失败时回退 OpenGL
        //   - prefer_opengl  优先使用 OpenGL，失败时回退 Vulkan
        //
        // 注意：这里的 graphicsApi 与启动器的 renderer（libgl4es/libMoltenVK 等 native 库选择）
        // 是两个不同的维度：
        //   - renderer：启动器加载哪个 native 渲染器库（LWJGL 层）
        //   - graphicsApi：MC 26.2+ 内部走 OpenGL 路径还是 Vulkan 路径（游戏层）
        //
        // 当用户选择 prefer_vulkan 时，建议同步将 renderer 设为 libMoltenVK.dylib
        // （UI 层会给出推荐，但不强制联动，允许高级用户分开配置）。
        //
        // 旧版本 MC（1.21.7 及以下）不识别 options.txt 中的 graphicsApi 字段，
        // 会被忽略，无副作用。
        //
        // 关键修复（更改图形 API 无效）：
        //   之前当 graphicsApi 为 "default" 时直接跳过，不写入 options.txt。
        //   这导致用户从 prefer_vulkan/prefer_opengl 切换回 default 时，
        //   options.txt 中残留的旧值不会被清除，MC 继续使用旧值而非内部默认。
        //   现在改为：
        //   - "default"：从 options.txt 中移除 graphicsApi 行，让 MC 使用内部默认
        //   - prefer_vulkan/prefer_opengl：写入对应值（覆盖旧值）
        String graphicsApi = System.getenv("AMETHYST_GRAPHICS_API");
        if (graphicsApi != null && !graphicsApi.isEmpty()) {
            MCOptionUtils.load();
            if ("default".equalsIgnoreCase(graphicsApi)) {
                // 选择"默认"时移除 options.txt 中的 graphicsApi 行，
                // 让 MC 26.2+ 使用其内部默认行为（不读取此字段）
                MCOptionUtils.remove("graphicsApi");
                System.out.println("[PojavLauncher] MC 26.2+ graphicsApi cleared (default)");
            } else {
                String normalized;
                if ("vulkan".equalsIgnoreCase(graphicsApi) || "prefer_vulkan".equalsIgnoreCase(graphicsApi)) {
                    normalized = "prefer_vulkan";
                } else if ("opengl".equalsIgnoreCase(graphicsApi) || "prefer_opengl".equalsIgnoreCase(graphicsApi)) {
                    normalized = "prefer_opengl";
                } else {
                    normalized = graphicsApi.toLowerCase();
                }
                MCOptionUtils.set("graphicsApi", normalized);
                System.out.println("[PojavLauncher] MC 26.2+ graphicsApi set to " + normalized);
            }
            MCOptionUtils.save();
        }

        MinecraftAccount account = MinecraftAccount.load(args[0]);
        JMinecraftVersionList.Version version = Tools.getVersionInfo(args[1]);
        // ame274：判空前移——下一行即首次解引用 version.id，原 Task202 块内
        // 的 version!=null 迟到判空毫无防护价值。null 只会来自 getVersionInfo
        // 对空/畸形 JSON 返回 null，此处立即给出可定位的错误而非裸 NPE。
        if (version == null) {
            throw new RuntimeException("Version JSON for '" + args[1]
                    + "' parsed to null (malformed or empty file)");
        }
        System.out.println("Launching Minecraft " + version.id);

        // Task94: LWJGL 版本上报链路诊断（原位置的检查被错误地嵌在 vulkan-only 的
        // if 块里从未执行过——括号错位，本行从未在日志中出现即为实证）。现移到
        // getVersionInfo 之后：此时 preProcessLibraries 已从实例 version.json 捕获
        // org.lwjgl:lwjgl:<ver> 并写入 org.lwjgl.version.report，Sodium 的
        // PreLaunchChecks 版本门据此放行（1.20.1 要求 3.3.1，26.x 要求 3.4.1）。
        // 同时保留“classpath 集合与 native 选择一致”的原有 sanity 目的。
        String activeLwjgl = System.getProperty("pojav.lwjgl.version");
        if (activeLwjgl != null) {
            try {
                String versionStr = Class.forName("org.lwjgl.Version").getMethod("getVersion").invoke(null).toString();
                System.out.println("[PojavLauncher] LWJGL selected by launcher: " + activeLwjgl
                    + ", reported version: " + versionStr
                    + " (metadata: " + System.getProperty("org.lwjgl.version.report", "not captured") + ")");
            } catch (ReflectiveOperationException e) {
                System.out.println("[PojavLauncher] LWJGL selected by launcher: " + activeLwjgl
                    + ", failed to read org.lwjgl.Version: " + e);
            }
        }

        // 第三个参数为服务器地址（FCL 风格）：留空则不自动加入，非空则启动后自动加入
        // 由 JavaLauncher.m 在 NSDictionary 启动分支以 args[2] 传入
        String serverIp = (args.length > 2 && args[2] != null) ? args[2] : "";

        // Set language to Chinese on first launch
        // For Minecraft 1.11 and later: zh_cn (lowercase)
        // For Minecraft 1.6 to 1.10: zh_CN (uppercase)
        // For Minecraft 1.1 to 1.5: zh_CN (uppercase, lowercase crashes)
        MCOptionUtils.load();
        String minecraftVersion = version.id;
        // ame270：数值化版本比较——原 String.compareTo 字典序会把 "1.9"~"1.9.5"
        // 判成 > "1.11"（老版本误写 zh_cn 小写 → 启动崩溃）。
        if (Tools.ame270McVersionAtLeast(minecraftVersion, 1, 11)) {
            MCOptionUtils.setDefault("lang", "zh_cn");
        } else if (Tools.ame270McVersionAtLeast(minecraftVersion, 1, 1)) {
            MCOptionUtils.setDefault("lang", "zh_CN");
        }
        // For Minecraft 1.0 and earlier, no language option
        MCOptionUtils.save();
        String configPath = null;
        // ★ Task275 J-P2-4：logging.client.file 两级解引用无判空——畸形 version JSON
        //   （第三方工具产物，Task173/ame270 有前科）"logging": {} 即裸 NPE 崩启动链。
        //   任一缺失落下方既有 log4j fallback（本就是为此兜底，只是没接上）。
        if (version.logging != null && version.logging.client != null
                && version.logging.client.file != null
                && version.logging.client.file.id != null) {
            if (version.logging.client.file.id.equals("client-1.12.xml")) {
                configPath = Tools.DIR_BUNDLE + "/log4j-rce-patch-1.12.xml";
            } else if (version.logging.client.file.id.equals("client-1.7.xml")) {
                configPath = Tools.DIR_BUNDLE + "/log4j-rce-patch-1.7.xml";
            } else {
                configPath = Tools.DIR_GAME_NEW + "/" + version.logging.client.file.id;
            }
        }
        // Fallback：如果 logging 配置缺失或文件不存在，使用 1.12 补丁配置
        // 确保 MC 日志能输出到 stdout，便于诊断启动崩溃
        if (configPath == null || !new java.io.File(configPath).exists()) {
            configPath = Tools.DIR_BUNDLE + "/log4j-rce-patch-1.12.xml";
            System.out.println("[PojavLauncher] Using fallback log4j config: " + configPath);
        }
        System.setProperty("log4j.configurationFile", configPath);

        // Task108：Task107 的 sodium-extra「reduce_resolution_on_mac」配置补丁已按
        // 用户要求撤销——用户确认 1.20.1 画面糊是自己的配置问题（该选项是用户自己
        // 开的），启动器不应每次启动强制改写用户模组配置。机制结论保留在
        // 使用问题（FAQ）标签页「画面模糊」条目：sodium-extra 在 Mac 伪装环境下会把
        // 帧缓冲减半，用户可在模组设置里自行关闭（追求帧率用 FSR 档位）。

        // Task202（E）：Forge + OptiFine 共存检测（26.1.2 崩溃定性）。
        // 病历（e4d704e 装机日志，Forge 26.1.2 会话）：崩溃链 =
        //   IForgeVertexFormat ClassNotFoundException + OptiFine 反射全面失败
        //   （OptiFine 构建与 Forge 64.1.3 的接口签名漂移：4 vs 5 参数）——
        //   整合包内携带的 OptiFine 与该 Forge 版本二进制不兼容，属模组侧
        //   问题，启动器无法代为修复（上游议题库同族崩溃均由移除 OptiFine
        //   解决）。检测仅打警示锚点（日志 + FAQ 指引），不阻断启动——
        //   用户可能装的是恰好兼容的版本，让游戏自己证明。
        // Task203（误报修复）：64fdaf2 装机日志实锤——用户已把 OptiFine 改名
        //   为 .jar.disabled（禁用），检测仍匹配（只查文件名含 "optifine"）
        //   并打出吓人的不兼容警告。加 .jar 后缀门：只有【活跃】的
        //   OptiFine（mods/*.jar）才告警，禁用副本（.jar.disabled / .disabled
        //   / .txt 等一切非 .jar 形态）不再触发。
        if (version.id != null
                && version.id.toLowerCase(java.util.Locale.ROOT).contains("forge")) {
            java.io.File ame202ModsDir = new java.io.File(Tools.DIR_GAME_NEW, "mods");
            String[] ame202ModsList = ame202ModsDir.isDirectory() ? ame202ModsDir.list() : null;
            if (ame202ModsList != null) {
                for (String ame202ModName : ame202ModsList) {
                    if (ame202ModName != null
                            && ame202ModName.toLowerCase(java.util.Locale.ROOT).endsWith(".jar")
                            && ame202ModName.toLowerCase(java.util.Locale.ROOT).contains("optifine")) {
                        System.out.println("[PojavLauncher] Task202: OptiFine detected alongside Forge (mods/"
                            + ame202ModName + ", version=" + version.id
                            + ") -- known-incompatible combination (IForgeVertexFormat CNFE / reflection"
                            + " signature drift on Forge 64.x); if the game crashes, remove OptiFine or use a"
                            + " matching build -- see the FAQ tab (使用问题)");
                        break;
                    }
                }
            }
        }

        Tools.launchMinecraft(account, version, serverIp);
    }
}
