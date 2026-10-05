package net.kdt.pojavlaunch;

import android.util.ArrayMap;
import com.google.gson.Gson;
import com.google.gson.GsonBuilder;
import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.io.BufferedWriter;
import java.io.File;
import java.io.FileFilter;
import java.io.FileInputStream;
import java.io.FileNotFoundException;
import java.io.FileOutputStream;
import java.io.FileWriter;
import java.io.InputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.PrintWriter;
import java.io.StringWriter;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.net.HttpURLConnection;
import java.net.URL;
import java.net.URLClassLoader;
import java.nio.charset.Charset;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Map;
import net.kdt.pojavlaunch.uikit.UIKit;
import net.kdt.pojavlaunch.utils.JSONUtils;
import net.kdt.pojavlaunch.value.DependentLibrary;
import net.kdt.pojavlaunch.value.MinecraftAccount;
import net.kdt.pojavlaunch.value.MinecraftLibraryArtifact;

public final class Tools {
    public static final Gson GLOBAL_GSON = new GsonBuilder().setPrettyPrinting().create();

    public static final String DIR_BUNDLE = System.getenv("BUNDLE_PATH"); // path to "PojavLauncher.app"
    public static final String DIR_GAME_HOME = System.getenv("POJAV_HOME");
    public static final String DIR_GAME_NEW = System.getenv("POJAV_GAME_DIR"); // path to "Library/Application Support/minecraft"
    public static final String DIR_GAME_PROFILE = System.getProperty("user.dir");
    
    public static final String DIR_APP_DATA = System.getenv("POJAV_HOME");
    public static final String DIR_ACCOUNT_NEW = DIR_APP_DATA + "/accounts";

    // New since 2.4.2
    public static final String DIR_HOME_VERSION = DIR_GAME_NEW + "/versions";
    public static final String DIR_HOME_LIBRARY = DIR_GAME_NEW + "/libraries";

    public static final String ASSETS_PATH = DIR_GAME_NEW + "/assets";
    public static final String OBSOLETE_RESOURCES_PATH=DIR_GAME_NEW + "/resources";

    public static void launchMinecraft(MinecraftAccount profile, final JMinecraftVersionList.Version versionInfo, String serverIp) throws Throwable {
        // --- BEGIN AMETHYST UPSTREAM LWJGL 3.4.1 COMPLIANCE OVERRIDE ---
        // 关闭 native libffi 检查（防止 LibFFI <clinit> 中的 NoSuchFieldError）
        // 注意：allocator 由 JavaLauncher.m 通过 -Dorg.lwjgl.system.allocator=system 统一配置，
        // 这里不再重复设置。原代码 System.setProperty("org.lwjgl.system.Allocator", "Custom")
        // 存在两个致命问题导致其从未生效，且会误导调试：
        //   1) 属性名大小写错误：LWJGL 实际读取小写 org.lwjgl.system.allocator，大写 Allocator 被忽略
        //   2) "Custom" 不是 LWJGL 有效 allocator 值（有效值仅 system/jemalloc/rpmalloc）
        System.setProperty("org.lwjgl.system.libffi.enabled", "false");
        System.setProperty("org.lwjgl.system.libffi.initialize", "false"); // Prevents NoSuchFieldError in LibFFI <clinit>

        // spvc / openal 库加载说明：
        // spvc 库名由 JavaLauncher.m 显式设置 -Dorg.lwjgl.spvc.libname=spirv-cross-c-shared.0
        // （参照 catsruledogs/Amethyst-iOS-25，能正常启动 26.2 + Java 25）。
        // LWJGL Library.loadNative 在 macOS 上对 libname 的处理：
        //   - 若 libname 已含 "lib" 前缀和 ".dylib" 后缀，直接使用
        //   - 否则加 "lib" 前缀和 ".dylib" 后缀
        // "spirv-cross-c-shared.0" -> "libspirv-cross-c-shared.0.dylib"（正确，不会二次包装）。
        // spirv-cross 作为共享 dylib 放在根目录 Frameworks/，从 library.path
        // （Frameworks:Frameworks/lwjglXX）的根目录 Frameworks/ 加载。
        //
        // openal：JavaLauncher.m 通过 -Dorg.lwjgl.openal.libname 钉死到
        // Frameworks/libopenal.dylib（Task112 防 classpath 劫持；该文件自 Task129 起为
        // re-export 垫片：1.20.1 impl + ALC_SOFT_system_events 桩，26.1.2 崩溃修复），
        // 本文件无需再 override。
        //
        // 历史教训：曾尝试移除 spvc.libname override 改用 Makefile 软链接
        // （libspirv-cross.dylib -> libspirv-cross-c-shared.0.dylib）+ LWJGL 默认名 "spirv-cross"，
        // 但 26.2 启动时在 "Now starting game" 阶段 SIGSEGV at get_method_id。根因：软链接方案
        // 依赖构建阶段正确创建符号链接，一旦构建环境差异导致软链接缺失或指向错误，spvc 加载
        // 进入异常状态，JNI 注册状态不一致，get_method_id 访问已损坏类元数据导致 SIGSEGV
        // （而非抛出 UnsatisfiedLinkError）。显式指定完整 SO 名直接定位实际文件，无需软链接，
        // 是最稳妥的方案。
        // --- END AMETHYST UPSTREAM LWJGL 3.4.1 COMPLIANCE OVERRIDE ---

        String[] launchArgs = getMinecraftArgs(profile, versionInfo, serverIp);
        // System.out.println("Minecraft Args: " + Arrays.toString(launchArgs));

        final String launchClassPath = generateLaunchClassPath(versionInfo);

        System.out.println("Args init finished. Now starting game");

        PojavClassLoader loader = (PojavClassLoader) ClassLoader.getSystemClassLoader();
        // add launcher.jar itself
        for (String s : System.getProperty("java.class.path").split(":")) {
            loader.appendToClassPathForInstrumentation(s);
        }
        for (String s : launchClassPath.split(":")) {
            if (!s.isEmpty()) {
                loader.addURL(new File(s).toURI().toURL());
            }
        }

        // --- BEGIN Task 154: Task152b Mithril GL pinning RETIRED ---
        // 病历（7c32bc3 装机日志，3b35b26 构建，Mithril 会话）：Task152b 在
        // MC main 之前经【系统类加载器】初始化 GL/Library 类并 dlopen
        // liblwjgl.dylib —— MC 侧 Knot 类加载器随后在自己的 Library.<clinit>
        // 里再次 System.loadLibrary("lwjgl")，JVM 的"同一原生库不得跨类加载器
        // 重复加载"不变量被击破（already loaded in another class loader），
        // 异常被 LWJGL 的 catch 吞掉后伪装成 "Failed to locate library:
        // liblwjgl.dylib" → 4.0 后端在 NativeLibrariesBootstrap 阶段闪退。
        // Task152b 的前提（"设备 lwjgl-opengl.jar GL.class 不读
        // org.lwjgl.opengl.libname"）经 jar 实检证伪——lwjgl-341/333 的
        // lwjgl-opengl.jar GL.create() MACOSX 分支自带该读取（c71dcfa 起存在）
        // ，-D 注入直接生效；Run #356 的 "no OpenGL context" 根因是
        // GL.create(SharedLibrary) Delegate 对 eglGetProcAddress 的间接层
        //（Mithril 的 eglGetProcAddress 对核心 gl* 返回坏指针），已由
        // scripts/patch_lwjgl_delegate_dlsym.py（Task154，与 Task145 同款
        // 字节码手术）改为直走 dlsym 解析——provider 命中 Mithril 自身导出
        // （_glGetString/_glGetIntegerv/_glGetError 已在导出表核实）。
        // 此处不再做任何预加载/反射钉扎：零跨加载器副作用，MC 自己的
        // GL.create() 读 -Dorg.lwjgl.opengl.libname（JavaLauncher Task146
        // 绝对路径推送）即得正确 provider。
        // --- END Task 154 ---

        Class<?> clazz = loader.loadClass(versionInfo.mainClass);
        Method method = clazz.getMethod("main", String[].class);
        // Task 86: 启动看门狗——在调用 Minecraft main 之前布防（见 startLaunchWatchdog javadoc 病历）
        startLaunchWatchdog(Thread.currentThread());
        method.invoke(null, new Object[]{launchArgs});
    }

    /**
     * Task 86: 启动看门狗 —— 大型整合包首启卡死诊断。
     *
     * 病历（e7230da 装机日志，BMC2 [FABRIC] 1.20.1，537 mods）：主线程在 Fabric 客户端
     * entrypoint 阶段被硬阻塞——JVM 启动 5.6s 后零 GC、零 JIT 编译、零日志，187s 后
     * 用户手动取消，启动浮层以 launch error 收场（"卡在启动界面"）。最后一个有日志的
     * mod 是 configureddefaults（"Applying default files..."），阻塞点在其后的某个
     * mod 初始化里；无栈采样无法进一步定位。
     *
     * 本看门狗在游戏主线程（即调用 Minecraft main 的当前线程）外侧周期采样并打印调用栈，
     * 下次复现时日志将直接给出阻塞的 mod 与调用点。采样分两阶段：
     *   阶段 1（entrypoint 期，线程尚未改名为 "Render thread"）：每 15s 一次全量栈转储
     *           （前 24 帧），最多 10 分钟；连续阻塞时自动压缩为单行心跳避免刷屏。
     *   阶段 2（窗口建立后，即资源重载/标题屏/进世界期）：每 30s 采样，仅当栈顶 6 帧
     *           连续 2 次完全一致（疑似冻结 >= 60s）才转储，最多 5 次。
     * 健康启动的总开销为个位数行日志；线程终止或 JVM 关闭时静默退出。
     */
    private static void startLaunchWatchdog(final Thread gameThread) {
        Thread watchdog = new Thread(new Runnable() {
            @Override
            public void run() {
                final String renderThreadName = "Render thread";
                String lastName = gameThread.getName();
                String lastDumpSignature = null;
                try {
                    // 阶段 1：Fabric entrypoint / 早期启动
                    for (int i = 1; i <= 40; i++) {
                        Thread.sleep(15000L);
                        Thread.State state = gameThread.getState();
                        if (state == Thread.State.TERMINATED) {
                            return;
                        }
                        String name = gameThread.getName();
                        if (!name.equals(lastName)) {
                            log("game thread renamed: " + lastName + " -> " + name);
                            lastName = name;
                        }
                        if (renderThreadName.equals(name)) {
                            log("launch reached MinecraftClient (window init), sample #" + i);
                            runPostWindowPhase(gameThread);
                            return;
                        }
                        StackTraceElement[] st = gameThread.getStackTrace();
                        String signature = stackSignature(st, 6);
                        if (signature != null && signature.equals(lastDumpSignature)) {
                            // 连续阻塞在同一位置：压缩为单行心跳
                            log("entrypoint-phase sample #" + i + " STILL blocked at "
                                    + (st.length > 0 ? st[0] : "?"));
                        } else {
                            dumpStack("entrypoint-phase", i, state, st);
                            lastDumpSignature = signature;
                        }
                    }
                } catch (InterruptedException e) {
                    // JVM 正在关闭：静默退出
                }
            }
        }, "Launch-Watchdog");
        watchdog.setDaemon(true);
        watchdog.start();
    }

    /** 阶段 2：窗口建立后的资源加载/标题屏阶段，冻结检测转储（见 javadoc）。 */
    private static void runPostWindowPhase(Thread gameThread) {
        String frozenSignature = null;
        int frozenCount = 0;
        int dumps = 0;
        try {
            // 20 次 x 30s = 10 分钟
            for (int i = 1; i <= 20 && dumps < 5; i++) {
                Thread.sleep(30000L);
                if (gameThread.getState() == Thread.State.TERMINATED) {
                    return;
                }
                StackTraceElement[] st = gameThread.getStackTrace();
                String signature = stackSignature(st, 6);
                if (signature != null && signature.equals(frozenSignature)) {
                    frozenCount++;
                    if (frozenCount >= 2) {
                        dumpStack("post-window-frozen", i, gameThread.getState(), st);
                        dumps++;
                        // 要求签名变化后才能再次触发，避免同一次冻结反复转储
                        frozenSignature = null;
                        frozenCount = 0;
                    }
                } else {
                    frozenSignature = signature;
                    frozenCount = 0;
                }
            }
        } catch (InterruptedException e) {
            // JVM 正在关闭：静默退出
        }
    }

    /** 取栈顶 maxFrames 帧拼接为签名字符串（空栈返回 null）。 */
    private static String stackSignature(StackTraceElement[] st, int maxFrames) {
        if (st == null || st.length == 0) {
            return null;
        }
        StringBuilder sb = new StringBuilder();
        int n = Math.min(maxFrames, st.length);
        for (int i = 0; i < n; i++) {
            sb.append(st[i]).append('|');
        }
        return sb.toString();
    }

    /** 打印一次完整栈转储（前 24 帧），带统一前缀便于日志检索。 */
    private static void dumpStack(String phase, int sample, Thread.State state, StackTraceElement[] st) {
        log(phase + " sample #" + sample + " state=" + state
                + " stack (" + (st == null ? 0 : st.length) + " frames):");
        if (st == null) {
            return;
        }
        int n = Math.min(24, st.length);
        for (int i = 0; i < n; i++) {
            System.out.println("[LaunchWatchdog]   at " + st[i]);
        }
        // Task 87：桌面弹窗/锁等待阻塞识别（仅提示一次）
        maybeLogStartupBlockHint(st);
    }

    /**
     * Task 87：启动阻塞模式识别——栈顶 Object.wait 直接位于 mod 代码之下。
     *
     * 病历（7b88b69，BMC2 537 mods）：missingmodschecker 的 MissingModsWindow.open
     * 在窗口构建完成后于 Object.wait() 等待用户点击——此时栈上已经没有任何
     * java.awt/javax.swing 帧（构建已返回），纯 AWT 帧扫描会漏掉这种"弹窗后
     * 等待"形态。判据：栈顶为 java.lang.Object.wait/wait0，且其下 3 帧内出现
     * 非 JDK 帧（mod/游戏代码）。vanilla 启动期主线程不用 Object.wait
     * （future/latch 走 LockSupport.park），命中即为 mod 显式等待。
     */
    private static boolean isObjectWaitUnderAppFrames(StackTraceElement[] st) {
        if (st == null || st.length < 2) {
            return false;
        }
        boolean waiting = "java.lang.Object".equals(st[0].getClassName())
                && ("wait".equals(st[0].getMethodName()) || "wait0".equals(st[0].getMethodName()));
        if (!waiting) {
            return false;
        }
        for (int i = 1; i < Math.min(4, st.length); i++) {
            String cn = st[i].getClassName();
            if (cn.startsWith("java.") || cn.startsWith("jdk.") || cn.startsWith("sun.")) {
                continue;
            }
            return true;
        }
        return false;
    }

    /** Task 87：一次性输出启动阻塞的针对性指引（防刷屏）。 */
    private static boolean task87HintShown = false;

    private static void maybeLogStartupBlockHint(StackTraceElement[] st) {
        if (task87HintShown || st == null || st.length == 0) {
            return;
        }
        boolean awtInStack = false;
        int n = Math.min(16, st.length);
        for (int i = 0; i < n; i++) {
            String cn = st[i].getClassName();
            if (cn.startsWith("java.awt.") || cn.startsWith("javax.swing.")) {
                awtInStack = true;
                break;
            }
        }
        boolean waitUnderApp = isObjectWaitUnderAppFrames(st);
        if (!awtInStack && !waitUnderApp) {
            return;
        }
        task87HintShown = true;
        log("STARTUP BLOCK signature: "
                + (awtInStack ? "AWT/Swing frames on the game thread"
                              : "Object.wait held directly by mod code")
                + ". Desktop-only dialog mods (e.g. missingmodschecker) open a window that can never"
                + " be shown on iOS and will block startup forever at this point. Remove the mod owning"
                + " the topmost app frames above from the mods folder (rename its .jar to .jar.disabled);"
                + " known offenders are auto-disabled before launch (see [ModDialogGuard] Task87 lines)."
                + " This hint is printed once.");
    }

    private static void log(String msg) {
        System.out.println("[LaunchWatchdog] Task86 " + msg);
    }

    public static String[] getMinecraftArgs(MinecraftAccount profile, JMinecraftVersionList.Version versionInfo, String serverIp) {
        String username = profile.username.replace("Demo.", "");
        String versionName = versionInfo.id;
        if (versionInfo.inheritsFrom != null) {
            versionName = versionInfo.inheritsFrom;
        }

        File gameDir = new File(Tools.DIR_GAME_PROFILE);
        gameDir.mkdirs();
        // 确保 logs 目录存在，防止 Log4j RollingRandomAccessFileAppender
        // 因 logs/latest.log 路径不存在而抛出 FileNotFoundException
        new File(gameDir, "logs").mkdirs();

        Map<String, String> varArgMap = new ArrayMap<String, String>();
        varArgMap.put("auth_session", profile.accessToken); // For legacy versions of MC
        varArgMap.put("auth_access_token", profile.accessToken);
        varArgMap.put("auth_player_name", username);
        varArgMap.put("auth_uuid", profile.profileId.replace("-", ""));
        varArgMap.put("auth_xuid", profile.xuid);
        varArgMap.put("assets_root", Tools.ASSETS_PATH);
        varArgMap.put("assets_index_name", versionInfo.assets);
        varArgMap.put("clientid", profile.clientToken);
        varArgMap.put("game_assets", Tools.ASSETS_PATH);
        varArgMap.put("game_directory", gameDir.getAbsolutePath());
        varArgMap.put("user_properties", "{}");
        varArgMap.put("user_type", "mojang");
        varArgMap.put("version_name", versionName);
        varArgMap.put("version_type", versionInfo.type);
        varArgMap.put("natives_directory", System.getProperty("java.library.path"));

        List<String> minecraftArgs = new ArrayList<String>();
        if (versionInfo.arguments != null) {
            // Support Minecraft 1.13+
            // 检测当前账户是否为第三方认证账户（authlib-injector / Yggdrasil）
            // Task220：显式 accountType 优先（与原生端 BaseAuthenticator.loadSavedName
            // / AccountList 标签统一口径）。旧版 clientToken+xuid 键位嗅探在混合
            // 文件（微软 xuid 与第三方 clientToken 并存）上会误判成微软账户，
            // 装机日志实锤 authlib-injector 会话打出 "Setting accountType to msa"
            // 的串类证据（正版账号被按第三方链路启动，皮肤/联机全废）。
            // 对第三方账户，即使版本 JSON 含 --xuid 参数，user_type 也必须保持 "mojang"
            // 而不能改为 "msa"，否则 Minecraft 26.x 内部会按 MSA 流程处理
            // 导致认证失败（无法加载皮肤 / 无法加入服务器 / 崩溃）
            boolean isThirdPartyAccount;
            if (profile.accountType != null && !profile.accountType.isEmpty()) {
                isThirdPartyAccount = "thirdparty".equals(profile.accountType);
            } else {
                // 旧文件回退：clientToken 非 "0" 且 xuid 为 null 或 "0"
                //（Microsoft 账户有 xuid，本地账户 clientToken 为 "0"）
                isThirdPartyAccount = !"0".equals(profile.clientToken)
                    && (profile.xuid == null || "0".equals(profile.xuid));
            }
            for (Object arg : versionInfo.arguments.game) {
                if (arg instanceof String) {
                    minecraftArgs.add((String) arg);
                    if (arg.equals("--xuid") && !isThirdPartyAccount) {
                        // 仅对 Microsoft 账户（有 xuid）设置 user_type=msa
                        // 第三方账户保持 "mojang"，避免 26.x 认证流程错误
                        varArgMap.put("user_type", "msa");
                    }
                } else {
                    /*
                    JMinecraftVersionList.Arguments.ArgValue argv = (JMinecraftVersionList.Arguments.ArgValue) arg;
                    if (argv.values != null) {
                        minecraftArgs.add(argv.values[0]);
                    } else {
                        
                         for (JMinecraftVersionList.Arguments.ArgValue.ArgRules rule : arg.rules) {
                         // rule.action = allow
                         // TODO implement this
                         }
                         
                    }
                    */
                }
            }
        }
        String[] argsFromJson = JSONUtils.insertJSONValueList(
            splitAndFilterEmpty(
                versionInfo.minecraftArguments == null ?
                fromStringArray(minecraftArgs.toArray(new String[0])):
                versionInfo.minecraftArguments,
                profile
            ), varArgMap
        );

        // FCL 风格：启动后自动加入服务器。serverIp 为空时不追加任何参数，
        // 行为与原启动流程完全一致。版本判定使用解析后的基础 MC 版本号
        // （versionName 优先取 inheritsFrom，避免 modded 版本 id 干扰比较）
        argsFromJson = appendServerArgs(argsFromJson, serverIp, versionName);

        // Task171：MC 26.4+ 的 PreferredGraphicsApi.DEFAULT 把后端尝试顺序
        // 翻转为 Vulkan 优先（26.3 是 GL 优先），且 26.4 的
        // OptionsForceDefaultGraphicsApiFix datafix 会把存量
        // preferredGraphicsBackend 重置回 "default"——本启动器选择的 GL
        // 转译渲染器（mg/zink/ANGLE/gl4es/...）会被 MC 原生 Vulkan 后端
        // 整层绕过（zink 配置全空转、Iris/光影失效；f26337d 装机日志
        // latestlog.old：26.4-snapshot-1 + mg 渲染器 -> "Using graphics
        // backend Vulkan, using drivers: 1.2.357 MoltenVK 1.4.2"，GL 路径
        // 从未被尝试）。追加 --graphicsBackend opengl 强制 GL 优先（26.3
        // 与 26.4-snapshot-1 的 Main 均已支持该参数，值域
        // default/opengl/vulkan）；GL 失败仍按 getBackendsToTry 顺序表回落
        // Vulkan，零新增风险。原生 Vulkan 渲染器（libMoltenVK）不追加——
        // 默认即 Vulkan 优先，语义正确。
        argsFromJson = appendGraphicsBackendArg(argsFromJson, versionName);

        // Tools.dialogOnUiThread(this, "Result args", Arrays.asList(argsFromJson).toString());
        return argsFromJson;
    }

    /**
     * Task 171：MC >= 26.4 时追加 --graphicsBackend opengl（GL 转译渲染器）。
     * 版本判定解析前导 "major.minor"（26.4-snapshot-1 -> 26.4），解析失败
     * 不追加（旧版本 joptsimple 对未知参数会直接抛异常，宁可漏加不可错加）。
     * 渲染器来自 AMETHYST_RENDERER 环境变量（JavaLauncher 在 JVM 启动前
     * setenv，System.getenv 可见）；含 MoltenVK = 原生 Vulkan 渲染器，跳过。
     */
    private static String[] appendGraphicsBackendArg(String[] args, String versionId) {
        if (versionId == null || !ame171IsMc264OrLater(versionId.trim())) {
            return args;
        }
        String renderer = System.getenv("AMETHYST_RENDERER");
        if (renderer != null && renderer.contains("MoltenVK")) {
            System.out.println("[Tools] Task171: MC " + versionId + " + native Vulkan renderer -> keep default backend order (vulkan first)");
            return args;
        }
        for (String a : args) {
            if ("--graphicsBackend".equals(a)) {
                System.out.println("[Tools] Task171: --graphicsBackend already present, not overriding");
                return args;
            }
        }
        List<String> argList = new ArrayList<String>(Arrays.asList(args));
        argList.add("--graphicsBackend");
        argList.add("opengl");
        System.out.println("[Tools] Task171: MC " + versionId
                + " defaults to Vulkan-first backend order; forcing --graphicsBackend opengl (renderer="
                + (renderer == null ? "<unset>" : renderer) + ")");
        return argList.toArray(new String[0]);
    }

    /** Task 171：解析前导 major.minor，判断是否 >= 26.4。 */
    private static boolean ame171IsMc264OrLater(String versionId) {
        java.util.regex.Matcher m = java.util.regex.Pattern
                .compile("^(\\d+)\\.(\\d+)").matcher(versionId);
        if (!m.find()) {
            return false;
        }
        try {
            int major = Integer.parseInt(m.group(1));
            int minor = Integer.parseInt(m.group(2));
            return major > 26 || (major == 26 && minor >= 4);
        } catch (NumberFormatException e) {
            return false;
        }
    }

    /**
     * 根据 serverIp 和 MC 版本追加服务器加入参数（FCL/ZL2 风格）。
     * - MC < 1.20：--server <host> --port <port>（端口缺省补 25565）
     * - MC >= 1.20：--quickPlayMultiplayer <host:port>（端口缺省补 :25565）
     * - 地址格式：host / host:port / [ipv6]:port
     * - 解析失败仅告警不加入，不抛出异常
     * - serverIp 为 null 或空字符串时直接返回原参数
     */
    private static String[] appendServerArgs(String[] args, String serverIp, String versionId) {
        if (serverIp == null || serverIp.isEmpty()) {
            return args;
        }
        String trimmed = serverIp.trim();
        if (trimmed.isEmpty()) {
            return args;
        }

        String host = null;
        String port = "25565"; // 默认端口

        // 地址解析：支持 host / host:port / [ipv6]:port
        if (trimmed.startsWith("[")) {
            // IPv6 形如 [::1]:25565 或 [::1]
            int close = trimmed.indexOf("]");
            if (close <= 0) {
                System.err.println("[Tools] Invalid server address (unterminated IPv6 bracket): " + serverIp);
                return args;
            }
            host = trimmed.substring(1, close);
            if (close + 1 < trimmed.length()) {
                // 括号后应跟 :port
                String rest = trimmed.substring(close + 1);
                if (rest.startsWith(":")) {
                    String portStr = rest.substring(1);
                    if (!portStr.isEmpty()) {
                        port = portStr;
                    }
                } else if (!rest.isEmpty()) {
                    System.err.println("[Tools] Invalid server address (unexpected chars after IPv6 bracket): " + serverIp);
                    return args;
                }
            }
        } else {
            // 普通地址：以最后一个 : 分割端口
            int lastColon = trimmed.lastIndexOf(":");
            if (lastColon > 0) {
                host = trimmed.substring(0, lastColon);
                String portStr = trimmed.substring(lastColon + 1);
                if (!portStr.isEmpty()) {
                    port = portStr;
                }
            } else {
                host = trimmed;
            }
        }

        if (host == null || host.isEmpty()) {
            System.err.println("[Tools] Invalid server address (empty host): " + serverIp);
            return args;
        }

        List<String> argList = new ArrayList<String>(Arrays.asList(args));
        // 版本判定：MC < 1.20 用 --server/--port，MC >= 1.20 用 --quickPlayMultiplayer
        if (versionId.compareTo("1.20") < 0) {
            argList.add("--server");
            argList.add(host);
            argList.add("--port");
            argList.add(port);
            System.out.println("[Tools] Auto-join server (legacy): " + host + ":" + port);
        } else {
            argList.add("--quickPlayMultiplayer");
            argList.add(host + ":" + port);
            System.out.println("[Tools] Auto-join server (quickPlay): " + host + ":" + port);
        }
        return argList.toArray(new String[0]);
    }

    public static String fromStringArray(String[] strArr) {
        StringBuilder builder = new StringBuilder();
        for (int i = 0; i < strArr.length; i++) {
            if (i > 0) builder.append(" ");
            builder.append(strArr[i]);
        }

        return builder.toString();
    }

    private static String[] splitAndFilterEmpty(String argStr, MinecraftAccount profile) {
        List<String> strList = new ArrayList<String>();
        if(profile.username.startsWith("Demo.")) {
            strList.add("--demo");
        }
        for (String arg : argStr.split(" ")) {
            if (!arg.isEmpty()) {
                strList.add(arg);
            }
        }
        return strList.toArray(new String[0]);
    }

    public static String artifactToPath(DependentLibrary library) {
        if (library.downloads != null &&
            library.downloads.artifact != null &&
            library.downloads.artifact.path != null)
            return library.downloads.artifact.path;
        String[] libInfos = library.name.split(":");
        return libInfos[0].replaceAll("\\.", "/") + "/" + libInfos[1] + "/" + libInfos[2] + "/" + libInfos[1] + "-" + libInfos[2] + ".jar";
    }

/*
    private static String getLWJGL3ClassPath() {
        StringBuilder libStr = new StringBuilder();
        File lwjgl3Folder = new File(Tools.DIR_GAME_NEW, "lwjgl3");
        if (/* info.arguments != null && @lwjgl3Folder.exists()) {
            for (File file: lwjgl3Folder.listFiles()) {
                if (file.getName().endsWith(".jar")) {
                    libStr.append(file.getAbsolutePath() + ":");
                }
            }
            // Remove the ':' at the end
            libStr.setLength(libStr.length() - 1);
        }
        return libStr.toString();
    }
*/
    public static String generateLaunchClassPath(JMinecraftVersionList.Version info) {
        StringBuilder libStr = new StringBuilder(); //versnDir + "/" + version + "/" + version + ".jar:";

        String[] classpath = generateLibClasspath(info);

        // Debug: LWJGL 3 override
        // File lwjgl2Folder = new File(Tools.MAIN_PATH, "lwjgl2");

        /*
         File lwjgl3Folder = new File(Tools.MAIN_PATH, "lwjgl3");
         if (lwjgl3Folder.exists()) {
         for (File file: lwjgl3Folder.listFiles()) {
         if (file.getName().endsWith(".jar")) {
         libStr.append(file.getAbsolutePath() + ":");
         }
         }
         } else if (lwjgl2Folder.exists()) {
         for (File file: lwjgl2Folder.listFiles()) {
         if (file.getName().endsWith(".jar")) {
         libStr.append(file.getAbsolutePath() + ":");
         }
         }
         }
         */

        for (String perJar : classpath) {
            if (!new File(perJar).exists()) {
                System.out.println("Ignored non-exists file: " + perJar);
                continue;
            }
            libStr.append(perJar + ":");
        }
        libStr.append(DIR_HOME_VERSION + "/" + info.id + "/" + info.id + ".jar");

        return libStr.toString();
    }
    
    public static void moveInside(String from, String to) {
        File fromFile = new File(from);
        for (File fromInside : fromFile.listFiles()) {
            moveRecursive(fromInside.getAbsolutePath(), to);
        }
        fromFile.delete();
    }

    public static void moveRecursive(String from, String to) {
        moveRecursive(new File(from), new File(to));
    }

    public static void moveRecursive(File from, File to) {
        File toFrom = new File(to, from.getName());
        try {
            if (from.isDirectory()) {
                for (File child : from.listFiles()) {
                    moveRecursive(child, toFrom);
                }
            }
        } finally {
            from.getParentFile().mkdirs();
            from.renameTo(toFrom);
        }
    }

    public static void preProcessLibraries(DependentLibrary[] libraries) {
        // Ignore some libraries since they are unsupported (jinput, text2speech) or unused (LWJGL)
        // Support for text2speech is not planned, so skip it for now.
        for (int i = 0; i < libraries.length; i++) {
            DependentLibrary libItem = libraries[i];
            if (libItem.name.startsWith("com.mojang:text2speech") ||
                //libItem.name.startsWith("net.java.jinput") ||
                libItem.name.startsWith("net.java.dev.jna:platform:") ||
                libItem.name.startsWith("org.lwjgl") ||
                libItem.name.startsWith("tv.twitch")) {
                    // Task94: 在丢弃 org.lwjgl 条目前，捕获 version.json 声明的
                    // LWJGL 核心版本（"org.lwjgl:lwjgl:<ver>"，如 1.20.1 -> 3.3.1，
                    // 26.x -> 3.4.1）。overlay 的 org.lwjgl.Version.getVersion()
                    // 优先上报该值，Sodium PreLaunchChecks 的版本门
                    // （getVersion().startsWith(要求版本)）因此与 Mojang 为该 MC
                    // 版本配套的 LWJGL 一致。809b847 双日志（zink/LTW 双渲染器
                    // 同死于 sodium 0.5.13 的 "Installed version: 3.4.1 /
                    // Required version: 3.3.1"）的根因即旧 overlay 硬编码 3.4.1。
                    if (libItem.name.startsWith("org.lwjgl:lwjgl:")) {
                        String[] coord = libItem.name.split(":");
                        if (coord.length >= 3 && !coord[2].trim().isEmpty()) {
                            System.setProperty("org.lwjgl.version.report", coord[2].trim());
                            System.out.println("[Tools] LWJGL report version: " + coord[2].trim()
                                + " (from version metadata; sodium PreLaunchChecks gate, Task94)");
                        }
                    }
                    libItem._skip = true;
                    continue;
            }

            String[] version = libItem.name.split(":")[2].split("\\.");
            if (libItem.name.startsWith("net.java.dev.jna:jna:")) {
                // 强制将 JNA 替换为 5.13.0 以保证 iOS 兼容性。
                // MC 26.3+ 要求 JNA 5.17.0，但其 darwin-aarch64 libjnidispatch 在 iOS 上
                // 加载 IOKit/CoreFoundation 后会导致 native crash/卡死（26.2 + JNA 5.13.0 正常）。
                // MC 不直接使用 JNA API（通过 oshi 间接使用），5.13.0 的 API 完全兼容。
                // PatchJNAAgent 会替换 Platform.class，与 JNA jar 版本无关。
                if (Integer.parseInt(version[0]) == 5 && Integer.parseInt(version[1]) == 13 && Integer.parseInt(version[2]) == 0) continue;
                System.out.println("[Tools] Replacing JNA " + version[0] + "." + version[1] + "." + version[2] + " with 5.13.0 for iOS compatibility");

createLibraryInfo(libItem);
                libItem.name = "net.java.dev.jna:jna:5.13.0";
                libItem.downloads.artifact.path = "net/java/dev/jna/jna/5.13.0/jna-5.13.0.jar";
                libItem.downloads.artifact.url = "https://libraries.minecraft.net/net/java/dev/jna/jna/5.13.0/jna-5.13.0.jar";
            } else if (libItem.name.startsWith("org.ow2.asm:asm-all:")) {
                if(Integer.parseInt(version[0]) >= 5) continue;
                //System.out.println("Library " + libItem.name + " has been changed to version 5.0.4");
                createLibraryInfo(libItem);
                libItem.name = "org.ow2.asm:asm-all:5.0.4";
                libItem.url = null;
                libItem.downloads.artifact.path = "org/ow2/asm/asm-all/5.0.4/asm-all-5.0.4.jar";
                libItem.downloads.artifact.sha1 = "e6244859997b3d4237a552669279780876228909";
                libItem.downloads.artifact.url = "https://repo1.maven.org/maven2/org/ow2/asm/asm-all/5.0.4/asm-all-5.0.4.jar";
            }
        }
    }

    private static void createLibraryInfo(DependentLibrary library) {
        if(library.downloads == null || library.downloads.artifact == null)
            library.downloads = new DependentLibrary.LibraryDownloads(new MinecraftLibraryArtifact());
    }

    public static String[] generateLibClasspath(JMinecraftVersionList.Version info) {
        List<String> libDir = new ArrayList<String>();

        preProcessLibraries(info.libraries);
        for (DependentLibrary libItem : info.libraries) {
            if (libItem._skip) continue;
            String fullPath = Tools.DIR_HOME_LIBRARY + "/" + artifactToPath(libItem);
            if (!libDir.contains(fullPath)) {
                libDir.add(fullPath);
            }
        }
        return libDir.toArray(new String[0]);
    }

    public static JMinecraftVersionList.Version getVersionInfo(String versionName) {
        try {
            JMinecraftVersionList.Version customVer = Tools.GLOBAL_GSON.fromJson(read(DIR_HOME_VERSION + "/" + versionName + "/" + versionName + ".json"), JMinecraftVersionList.Version.class);
            if (customVer.inheritsFrom == null || customVer.inheritsFrom.equals(customVer.id)) {
                return customVer;
            } else {
                JMinecraftVersionList.Version inheritsVer = Tools.GLOBAL_GSON.fromJson(read(DIR_HOME_VERSION + "/" + customVer.inheritsFrom + "/" + customVer.inheritsFrom + ".json"), JMinecraftVersionList.Version.class);
                // Task173（旧版 Forge 崩溃修复）：父版本 JSON 缺失/解析失败时 inheritsVer
                // 为 null，旧代码下一行 inheritsVer.inheritsFrom = inheritsVer.id 直接 NPE，
                // 用户看到的是被 RuntimeException 包装后毫无信息的崩溃（815 行）。
                // 老版 Forge（1.8.9-forge-11.15.1.2318-bbc7aad9 装机实录：752 行 NPE）
                // 的继承链问题在此一并防御：报出可定位的错误而非裸 NPE。
                if (inheritsVer == null) {
                    throw new RuntimeException("Parent version JSON for '" + customVer.inheritsFrom
                            + "' is missing or unreadable (required by '" + versionName + "')");
                }
                inheritsVer.inheritsFrom = inheritsVer.id;
                
                insertSafety(inheritsVer, customVer,
                             "assetIndex", "assets", "id",
                             "mainClass", "minecraftArguments",
                             "releaseTime", "time", "type"
                             );

                // Task173（旧版 Forge 崩溃修复，装机 NPE 实锤）：MCDL 生成的老版
                // Forge JSON 可能没有 "libraries" 字段（customVer.libraries == null
                // → 752 行 for 循环 NPE；inheritsVer.libraries == null → 750 行
                // Arrays.asList NPE）。旧版 vanilla JSON 理论上恒有 libraries，但
                // 老 Forge/整合包生成的 JSON 不保证。空数组兜底：无 libraries 的
                // 自定义版本不再崩溃，仅跳过“同名替换”逻辑。
                DependentLibrary[] customLibraries =
                        (customVer.libraries != null) ? customVer.libraries : new DependentLibrary[0];
                DependentLibrary[] inheritLibraries =
                        (inheritsVer.libraries != null) ? inheritsVer.libraries : new DependentLibrary[0];

                // Go through the libraries, remove the ones overridden by the custom version
                List<DependentLibrary> inheritLibraryList = new ArrayList<>(Arrays.asList(inheritLibraries));
                outer_loop:
                for(DependentLibrary library : customLibraries){
                    // Clean libraries overridden by the custom version
                    if (library == null || library.name == null) {
                        continue;
                    }
                    String libName = library.name.substring(0, library.name.lastIndexOf(":"));

                    for(DependentLibrary inheritLibrary : inheritLibraryList) {
                        if (inheritLibrary == null || inheritLibrary.name == null) {
                            continue;
                        }
                        String inheritLibName = inheritLibrary.name.substring(0, inheritLibrary.name.lastIndexOf(":"));

                        if(libName.equals(inheritLibName)){
                            System.out.println("Library " + libName + ": Replaced version " +
                                    libName.substring(libName.lastIndexOf(":") + 1) + " with " +
                                    inheritLibName.substring(inheritLibName.lastIndexOf(":") + 1));

                            // Remove the library , superseded by the overriding libs
                            inheritLibraryList.remove(inheritLibrary);
                            continue outer_loop;
                        }
                    }
                }

                // Fuse libraries
                inheritLibraryList.addAll(Arrays.asList(customLibraries));
                inheritsVer.libraries = inheritLibraryList.toArray(new DependentLibrary[0]);
                preProcessLibraries(inheritsVer.libraries);

                // Inheriting Minecraft 1.13+ with append custom args
                if (inheritsVer.arguments != null && customVer.arguments != null) {
                    List totalArgList = new ArrayList();
                    totalArgList.addAll(Arrays.asList(inheritsVer.arguments.game));
                    
                    int nskip = 0;
                    for (int i = 0; i < customVer.arguments.game.length; i++) {
                        if (nskip > 0) {
                            nskip--;
                            continue;
                        }
                        
                        Object perCustomArg = customVer.arguments.game[i];
                        if (perCustomArg instanceof String) {
                            String perCustomArgStr = (String) perCustomArg;
                            // Check if there is a duplicate argument on combine
                            if (perCustomArgStr.startsWith("--") && totalArgList.contains(perCustomArgStr)) {
                                perCustomArg = customVer.arguments.game[i + 1];
                                if (perCustomArg instanceof String) {
                                    perCustomArgStr = (String) perCustomArg;
                                    // If the next is argument value, skip it
                                    if (!perCustomArgStr.startsWith("--")) {
                                        nskip++;
                                    }
                                }
                            } else {
                                totalArgList.add(perCustomArgStr);
                            }
                        } else if (!totalArgList.contains(perCustomArg)) {
                            totalArgList.add(perCustomArg);
                        }
                    }

                    inheritsVer.arguments.game = totalArgList.toArray(new Object[0]);
                }

                return inheritsVer;
            }
        } catch (Exception e) {
            throw new RuntimeException(e);
        }
    }

    // Prevent NullPointerException
    private static void insertSafety(JMinecraftVersionList.Version targetVer, JMinecraftVersionList.Version fromVer, String... keyArr) {
        for (String key : keyArr) {
            Object value = null;
            try {
                Field fieldA = fromVer.getClass().getField(key);
                value = fieldA.get(fromVer);
                if (((value instanceof String) && !((String) value).isEmpty()) || value != null) {
                    Field fieldB = targetVer.getClass().getField(key);
                    fieldB.set(targetVer, value);
                }
            } catch (Throwable th) {
                System.err.println("Unable to insert " + key + "=" + value);
                th.printStackTrace();
            }
        }
    }
    
    public static String convertStream(InputStream inputStream) throws IOException {
        return convertStream(inputStream, Charset.forName("UTF-8"));
    }
    
    public static String convertStream(InputStream inputStream, Charset charset) throws IOException {
        String out = "";
        int len;
        byte[] buf = new byte[512];
        while((len = inputStream.read(buf))!=-1) {
            out += new String(buf,0,len,charset);
        }
        return out;
    }

    public static void copy(final InputStream input, final OutputStream output) throws IOException {
        final byte[] buffer = new byte[8192];
        int n = 0;
        while ((n = input.read(buffer)) != -1) {
            output.write(buffer, 0, n);
        }
    }

    public static File lastFileModified(String dir) {
        File fl = new File(dir);

        File[] files = fl.listFiles(new FileFilter() {
                public boolean accept(File file) {
                    return file.isFile();
                }
            });

        long lastMod = Long.MIN_VALUE;
        File choice = null;
        for (File file : files) {
            if (file.lastModified() > lastMod) {
                choice = file;
                lastMod = file.lastModified();
            }
        }

        return choice;
    }

    public static String read(InputStream is) throws IOException {
        String out = "";
        int len;
        byte[] buf = new byte[512];
        while((len = is.read(buf))!=-1) {
            out += new String(buf,0,len);
        }
        return out;
    }

    public static String read(String path) throws IOException {
        return read(new FileInputStream(path));
    }

    public static void write(String path, byte[] content) throws IOException
    {
        File outPath = new File(path);
        outPath.getParentFile().mkdirs();
        outPath.createNewFile();

        BufferedOutputStream fos = new BufferedOutputStream(new FileOutputStream(path));
        fos.write(content, 0, content.length);
        fos.close();
    }

    public static void write(String path, String content) throws IOException {
        write(path, content.getBytes());
    }
}
