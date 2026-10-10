#import "LauncherPreferences.h"
#import "PLPreferences.h"
#import "UIKit+hook.h"
#import "config.h"
#import "utils.h"

NSString *const PREF_DOWNLOAD_SOURCE_MOD = @"general.download_source_mod";
NSString *const PREF_DOWNLOAD_SOURCE_SHADER = @"general.download_source_shader";
NSString *const PREF_DOWNLOAD_SOURCE_RESOURCEPACK = @"general.download_source_resourcepack";
NSString *const PREF_DOWNLOAD_SOURCE_DATAPACK = @"general.download_source_datapack";
NSString *const PREF_DOWNLOAD_SOURCE_MODPACK = @"general.download_source_modpack";
NSString *const PREF_DOWNLOAD_SOURCE_WORLD = @"general.download_source_world";
NSString *const PREF_DOWNLOAD_SOURCE_SERVER = @"general.download_source_server";
NSString *const PREF_CURSEFORGE_API_KEY = @"general.curseforge_api_key";
NSString *const PREF_MOD_UPDATE_KEEP_OLD = @"general.mod_update_keep_old";
NSString *const PREF_MOD_MIRROR = @"general.mod_mirror";

@interface PLPreferences()
@end

@implementation PLPreferences

+ (id)defaultPrefForGlobal:(BOOL)global {
    // Preferences that can be isolated
    NSMutableDictionary<NSString *, NSMutableDictionary *> *defaults = @{
        @"general": @{
            @"check_sha": @YES,
            @"cosmetica": @YES,
            @"debug_logging": @(!CONFIG_RELEASE),
            // Task 125：启动时自动检测更新（默认开；关闭后仅保留手动检查入口）
            @"auto_update_check": @YES,
            // Task 130：公告源改为本仓库托管的 announcements.json（旧上游
            // air-api.vercel.app 已 404；AnnouncementService 的 raw + jsDelivr
            // 源级联见同文件常量，此默认值同时是"未自定义"识别基准之一）
            // Task218：仓库名去 air（Gsjsjzhznsz/Prisma-Minecraft-iOS-Launcher）。
            @"news_url": @"https://raw.githubusercontent.com/Gsjsjzhznsz/Prisma-Minecraft-iOS-Launcher/main/announcements.json",
            // Task218：旧版全局下载源键的默认值退役（注释化——本键已无任何
            // 写入方，键不存在不影响任何读写）。旧默认 "bmclapi" 会被
            // setDefaultsForPref 播种并落盘：① 让 Task138 声明的 speed_first
            // 出厂默认在首次启动即被迁移翻成 mirror_first；② 偏好重置后
            // 重新背上旧值。存量 plist 里已物化的值继续经 PLMirrorCenter
            // policyForType 的回退链生效（读侧兼容零变动）。
            // @"download_source": @"bmclapi",   // retired by Task218
            // 各资源类型独立下载源（未显式设置时回退到 modrinth）
            @"download_source_mod": @"modrinth",
            @"download_source_shader": @"modrinth",
            @"download_source_resourcepack": @"modrinth",
            @"download_source_datapack": @"modrinth",
            @"download_source_modpack": @"modrinth",
            @"download_source_world": @"modrinth",
            @"download_source_server": @"modrinth",
            // CurseForge API Key：空串代表使用编译时内置的默认 key
            @"curseforge_api_key": @"",
            // Task211：CF 源一次性迁移哨兵（ame211_migrateCfSourceToModrinth，
            // 见 LauncherPreferences.h 的 Task211 注释——无有效 Key 的设备把
            // 存量的 curseforge 源拨回 modrinth，用户定案"默认源改为 Modrinth"）
            @"task211_cf_source_migrated": @NO,
            // Mod 更新时是否保留旧文件（默认 YES）
            @"mod_update_keep_old": @YES,
            // 模组镜像源（Task138：设置行已移入 download 分区，选择写
            // download.assetSearchSource / assetDownloadSource；此键自此无
            // 消费方，仅为存量 plist 兼容保留默认值）
            @"mod_mirror": @"official",
            // profile 写入的强制内存分配，0=使用 java.allocated_memory/auto_ram 逻辑
            @"ram_allocation": @(0),
            // 首页公告磁贴预览级别：full（标题+日期+摘要）/ summary（标题+摘要）/ title_only（仅标题）
            @"announcement_preview_level": @"summary",
            // Task218：首次使用欢迎向导完成哨兵（WelcomeViewController 完成
            // 时置 YES；未置 = 首次启动，SceneDelegate 在根视图就绪后全屏
            // 弹出向导：语言 / 下载源 / 数据导入三步引导 + 动效）。
            @"welcome_completed": @NO,
        }.mutableCopy,
        // 分类镜像策略（值 official_first / mirror_first / speed_first，
        // 由 PLMirrorCenter 统一读取，未迁移时回退旧键 general.download_source）。
        // Task138：默认改为 speed_first（加载速度快优先，用户指令，参考 FCL
        // 测速策略）——显式设置过其它值的设备不受影响，仅"从未选择"的
        // 设备落到新默认。
        @"download": @{
            @"fileSource": @"speed_first",
            @"assetSearchSource": @"speed_first",
            @"assetDownloadSource": @"speed_first",
            @"modLoaderSource": @"speed_first",
            // 一次性迁移哨兵：YES 表示旧键 download_source 已迁移到上述 4 键，
            // 防止用户手动改新键后被重复迁移覆盖（见 LauncherPreferences.m migrateDownloadSourcePreferences）
            @"sourceMigrated": @NO,
        }.mutableCopy,
        @"video": @{ // Video & Audio
            @"renderer": @"auto",
            @"resolution": @(100),
            // max_framerate 选项已移除：CADisplayLink 始终采用 30-120Hz 自适应范围，
            // 由屏幕硬件能力决定实际帧率。保留 disable_game_vsync 作为唯一帧率解锁开关。
            // 解锁帧率（关闭垂直同步）：默认开启。
            // MC 默认 enableVsync=true，会把帧率锁在屏幕刷新率（60Hz 锁 60、120Hz ProMotion 锁 120）。
            // 开启后启动器会在三层联动关闭 VSync：options.txt 强制 enableVsync=false、
            // pojavSwapInterval 强制 interval=0、CAMetalLayer 三缓冲。详见各修改点注释。
            @"disable_game_vsync": @YES,
            @"performance_hud": @NO,
            @"fullscreen_airplay": @YES,
            @"silence_other_audio": @NO,
            @"silence_with_switch": @NO,
            @"fix_simple_voice_chat_mod": @NO,
            @"allow_microphone": @NO,
            // MC 26.2+ 游戏内 OpenGL/Vulkan 切换，空串=默认（由 JavaLauncher 处理）
            @"graphics_api": @""
        }.mutableCopy,
        @"control": @{
            // Task 77：默认触控布局改为 custom.json（用户需求“默认控件选择 custom”）。
            // 出厂保障链：main.m 启动时 generateAndSaveCustomControl() 从 App Bundle
            // 拷入 controlmap/custom.json（仅当缺失）；若极端情况下文件仍缺失/解析
            // 失败，ControlLayout.loadControlFile 的 Task64 防御性回落会加载
            // default.json 保住可玩性。已显式选择过布局的设备不受影响（存储值优先）。
            @"default_ctrl": @"custom.json",
            // Task 77 迁移哨兵：YES = default.json -> custom.json 出厂值切换已
            // 处理过（老安装一次性改写，见 LauncherPreferences.m migrateDefaultControlPref）。
            // 必须在此注册默认值：setPrefObject 只能写已存在的键。
            @"default_ctrl_migrated_custom": @NO,
            @"control_safe_area": UIApplication.sharedApplication ? NSStringFromUIEdgeInsets(getDefaultSafeArea()) : @"",
            @"default_gamepad_ctrl": @"default.json",
            @"controller_type": @"xbox",
            @"hardware_hide": @YES,
            @"recording_hide": @YES,
            @"gesture_mouse": @YES,
            @"gesture_hotbar": @YES,
            @"disable_haptics": @NO,
            @"slideable_hotbar": @NO,
            @"press_duration": @(400),
            @"button_scale": @(100),
            @"mouse_scale": @(100),
            @"mouse_speed": @(100),
            @"virtmouse_enable": @NO,
            // ★ Task230（反馈 #10：自动打开输入法（SDL）开关无效）：Task229
            // 加开关时漏注册默认值——PLPreferences 只能读写已注册的键
            //（Task142/143 mobileglues.renderer_backend 同款病历）：装机日志
            // .1:62-74 实锤 Setter 写入被静默丢弃（"Setter could not find
            // preference control.auto_keyboard_sdl"）→ Getter 恒回落默认
            // false → SurfaceVC 的 auto-keyboard 分支永不触发。注册后写读
            // 双向生效。
            @"auto_keyboard_sdl": @NO,
            @"gyroscope_enable": @NO,
            @"gyroscope_invert_x_axis": @NO,
            @"gyroscope_sensitivity": @(100),
            @"mod_touch_enable": @NO,
            @"mod_touch_mode": @0,
            @"mod_touch_vibrate_enable": @YES,
            @"mod_touch_vibrate_intensity": @2,
            @"mod_touch_moveview_enable": @YES,
            // Task 134：屏蔽控件——隐藏 mod 全部屏幕控件（写入空布局
            // 预设到 <游戏目录>/config/touchcontroller/，下次启动游戏生效）
            @"mod_touch_hide_controls": @NO,
            // UI 子面板占位 key（LauncherPreferencesViewController 的 getPreference 回调
            // 会对每个设置项按 "section.key" 查询，包括 button/childPane 类型）。
            // 提供空串默认值避免触发 "Getter could not find preference control.custom_controls" 日志。
            @"custom_controls": @""
        }.mutableCopy,
        @"java": @{
            @"java_homes": @{
                // Task159：新增 1_26_newer 预选槽位（26.0+ 默认 Java 25，
                // 与 Manage JRE 页新预选行配套；25 runtime 为内置捆绑）
                @"0": @{
                    @"1_16_5_older": @"8",
                    @"1_17_newer": @"17",
                    @"1_26_newer": @"25",
                    @"execute_jar": @"8"
                }.mutableCopy,
                @"8": @"internal",
                @"17": @"internal",
                @"21": @"internal",
                @"25": @"internal"
            }.mutableCopy,
            @"java_args": @"",
            @"env_variables": @"",
            @"auto_ram": @(!getEntitlementValue(@"com.apple.private.memorystatus")),
            @"allocated_memory": [NSNumber numberWithFloat:roundf((NSProcessInfo.processInfo.physicalMemory / 1048576) * 0.25)],
            // profile 写入的强制 Java 版本，auto=根据游戏版本自动选择
            @"java_version": @"auto"
        }.mutableCopy,
        // MobileGlues 渲染器偏好
        // 当渲染器选择为 MobileGlues 或 Vulkan 时，由 init_loadMobileGluesConfig() 写入
        // <POJAV_HOME>/MG/config.json，控制 GL 版本、ANGLE 后端、FSR 等。
        // Vulkan 渲染器的 OpenGL 回退使用 MobileGlues（对齐 Ynnyny 仓库），设置生效。
        // Auto 渲染器实际使用 ANGLE，不会加载 MobileGlues，这些设置不生效。
        @"mobileglues": @{
            // Task 133：enable_angle 默认删除——独立 "ANGLE ES 驱动" 开关已随
            // 用户指令退役（与 renderer_backend 的 GLES 后端重复冲突；且 MG
            // 源码 iOS 分支的 ES 路径无视该配置，属死配置）。ES/ANGLE 路径的
            // 唯一入口 = renderer_backend 选 GLES 后端。
            // Task 120：MobileGL 渲染后端单一选项（设置-视频-MobileGlues 区，
            // 与"ANGLE ES 驱动"并排）。上游的三个 MobileGL 家族列表条目
            // （MobileGL / MobileGL-gles / Mithril）合并进此选项：
            //   0=关闭（跟随渲染器选择） 1=Vulkan（默认） 2=GLES 3=Mithril。
            // 仅在渲染器为 auto（默认）时生效——显式渲染器选择永远优先
            // （旧 mobilegl_vulkan 布尔开关退役，见 Task120 注释）。
            // 默认 1（Vulkan）：用户实测上游 DirectVulkan 后端流畅度最高
            // （CAMetalLayer 直呈 + IMMEDIATE 呈现 + 无逐帧回读）。
            // Task 142：mg 后端独立存储键（渲染器层只存 "mg"，后端由此键
            // 决定，默认 Vulkan 直连）。Task 143 注册默认值——Task142 漏注册，
            // 而 PLPreferences 只能读写已存在的键（本函数头注释同款规矩），
            // 装机日志 4ecc256 实锤两向皆哑：
            //   "[PLPreferences] Setter could not find preference
            //    mobileglues.renderer_backend"（用户选 GLES 后端写入被静默
            //    丢弃）→ 启动永远回落默认 libMobileGL.dylib —— 用户反馈
            //    "无论切换什么渲染器都会变成mg" 的根因。
            // 默认值刻意为空串而非 libMobileGL.dylib：ame142_effective_
            // backend_key 的解析链（新键 → legacy 全局家族键 → legacy 档位
            // → 默认 Vulkan）依赖"键未设"语义落到 legacy 档位层——存量设备
            // renderer=auto + mobilegl_backend=2/3 的 GLES/Mithril 选择必须
            // 继续生效；注册成实体默认值会让空键恒命中第一层、legacy 档位
            // 永久失明。空串同样消除每帧 "Getter could not find" 日志噪音。
            @"renderer_backend": @"",
            @"mobilegl_backend": @(1),
            @"enable_no_error": @(0),
            @"enable_ext_timer_query": @YES,
            @"enable_ext_compute_shader": @NO,
            // Task 166：DSA 默认改为【关】（Task129d 的 @YES 曾把 MC 26.x
            // 推进 DSA 路径——MobileGlues 2.0.17 的 DSAWrapper 模拟层在 FSR1
            // fb0 重定向下自洽性不足，三会话 A/B 实锤黑屏；性能依据本就
            // 来自 zink（Mesa 原生 DSA）而非 MobileGlues）。用户仍可在偏好
            // 分区强制开回；zink 会话的 DSA 由 Mesa 自身暴露，不经此键。
            // Task129d 原注释（"意图与现实不符的纯 bug"）的历史现场见
            // LauncherPreferences.m 的 ame130 迁移函数与 Task166 反向迁移。
            @"enable_ext_direct_state_access": @NO,
            // Task 129d：着色器缓存 128MB（对齐代码内"安全默认值"；旧默认 32MB
            // 对重型整合包偏小，缓存逐出意味着着色器重编译卡顿）。
            @"max_glsl_cache_size": @(128),
            @"multidraw_mode": @(0),
            @"angle_depth_clear_fix_mode": @(0),
            @"custom_gl_version": @(0),
            @"fsr1_setting": @(0),
            // Task 130：FSR1 RCAS 锐化强度（mpv 口径 [0,1] 越大越锐）。
            // 0.2 = mpv 默认轻度锐化；负值 = 关闭 RCAS（仅 EASU）。
            // 消费链：JavaLauncher ame130_export_rcas_env -> config.json
            // fsr1RcasSharpness（MobileGlues）+ AMETHYST_FSR_RCAS_SHARPNESS
            // 环境变量（MobileGL/zink 的 mgl_fsr/osm_bridge）。
            @"fsr_rcas_sharpness": @0.2,
            // Task 130：性能默认值治愈迁移哨兵（ame130_migrateMgPerfDefaults，
            // 见 LauncherPreferences.h 根因注释——v5.1.0 持久化的旧默认 0/32
            // 压制 Task129d 新默认 1/128，本哨兵保证迁移只跑一次）
            @"task130_perf_defaults_migrated": @NO,
            // Task 166：DSA 黑屏反向迁移哨兵（ame166_migrateMgDsaBlackScreen，
            // 持久化 1 -> 0 一次性归零；见 LauncherPreferences.h 的 Task166 注释）
            @"task166_dsa_blackscreen_migrated": @NO
        }.mutableCopy,
        // 游戏内覆盖层（GameMenuOverlayView）的位置持久化与开关
        // 位置以屏幕宽高百分比存储（0.0~1.0），哨兵值 -1 表示未设置，
        // GameMenuOverlayView 的 restorePositions 会回退到硬编码默认位置。
        @"game": @{
            @"menu_button_x": @(-1.0),
            @"menu_button_y": @(-1.0),
            @"stats_label_x": @(-1.0),
            @"stats_label_y": @(-1.0),
            @"stats_label_visible": @YES,
            // ★ Task238（用户："在默认边边没有贴边"+装机日志
            //   "[PLPreferences] Setter could not find preference
            //    game.gear.docked"）：Task227 的吸边状态键从未注册——
            //   PLPreferences 只能读写已注册键（Task142/143 病历同款），
            //   setPrefBool 写入被静默丢弃 → 每次启动吸边状态丢失，齿轮
            //   以"贴边但不吸住"的悬浮球形态恢复。注册后写读双向生效。
            //   valueForKeyPath: 语义：game.gear.docked = game→gear→docked，
            //   内层字典必须可变（setValue:forKeyPath: 最后一跳落在它上面）。
            @"gear": [@{
                @"docked": @NO,
                @"docked_left": @NO
            } mutableCopy]
        }.mutableCopy,
        @"internal": @{
            @"isolated": @NO,
            @"latest_version": [NSDictionary new]
        }.mutableCopy
    }.mutableCopy;

    if (global) {
        // Preferences that cannot be isolated
        NSDictionary *general = @{
            @"game_directory": @"default",
            // Task 129g：默认值改由 UIDevice.model 推导（不受 UIKit+hook 的
            // idiom 改写影响，与 hook 的 iPad 机型直通 Pad 同口径）。
            @"hidden_sidebar": @([[[UIDevice currentDevice].model lowercaseString] containsString:@"iphone"]),
            @"appicon": @"AppIcon-Light",
            @"ui_layout": @"vs",
            // Task161：初次使用默认"跟随系统"（用户指令"外观模式默认跟随系统"，
            // 推翻 Task160 的 light 缺省；SceneDelegate 读 general.ui_theme，
            // auto -> UIUserInterfaceStyleUnspecified）。
            // 仅新装/重置偏好生效，存量用户已保存的值不变（设置页"外观模式"三档随时可改）。
            @"ui_theme": @"auto",
            // Task161：外观显式选择标记——用户在设置页亲手选过主题后置 YES；
            // SceneDelegate 的一次性迁移（历史默认值 dark/light → auto）只
            // 对未显式选择的设备生效，选过的永不覆盖。注册本键是
            // PLPreferences "只能读写已注册键" 规矩的硬要求（Task143 病历）。
            @"ui_theme_explicit": @NO,
            // 应用语言："system"=跟随系统，"zh-Hans"=简体中文，"en"=English
            @"app_language": @"system",
            @"multi_threaded": @NO,
            // 自定义外观颜色（hex 字符串，空串=使用默认深色毛玻璃/白色文字）
            @"text_color": @"",
            @"card_color": @"",
            // 主题强调色（hex 字符串，空串=回退到默认蓝 #429CF5，见 LauncherPreferences.m accentColor()）
            // 提供默认值避免每次访问触发 "Getter could not find preference general.accent_color" 日志
            @"accent_color": @""
        };
        [defaults[@"general"] addEntriesFromDictionary:general];

        defaults[@"java"][@"manage_runtime"] = @""; // stub
        defaults[@"debug"] = @{
            @"debug_universal_script_jit": @NO,
            @"debug_always_attached_jit": @NO,
            @"debug_skip_wait_jit": @NO,
            // Task 134：JIT 开启工具选择（auto = 原自动判定：TrollStore
            // 检测 → apple-magnifier；iOS>=17.4 → stikjit；16.7-17.3.1 →
            // sidestore）与 iOS 26 JS 脚本 JIT 开关（默认携带脚本）
            @"jit_enabler": @"auto",
            @"jit26_script_disable": @NO,
            @"debug_hide_home_indicator": @NO,
            // Task 129g：同 hidden_sidebar——model 推导，避免求值时机依赖。
            @"debug_ipad_ui": @([[[UIDevice currentDevice].model lowercaseString] containsString:@"ipad"]),
            @"debug_auto_correction": @YES,
            @"debug_show_layout_bounds": @NO,
            @"debug_show_layout_overlap": @NO
        }.mutableCopy;
        defaults[@"warnings"] = @{
            @"local_warn": @YES,
            @"mem_warn": @YES,
            @"auto_ram_warn": @YES,
            @"limited_ram_warn": @YES
        }.mutableCopy;
        // TODO: isolate this or add account picker into profile editor(?)
        defaults[@"internal"][@"selected_account"] = @"";
    }

    return defaults;
}

+ (id)getPreference:(NSString *)key from:(NSDictionary *)pref {
    for (NSDictionary *section in pref.allValues) {
        if ([section isKindOfClass:NSDictionary.class] && section[key]) {
            return section[key];
        }
    }
    return nil;
}

+ (id)getOldLayoutPreference:(NSString *)key from:(NSDictionary *)pref {
    // Find preference in the root dictionary first
    if (pref[key]) {
        return pref[key];
    }
    // Find preference in subdictionaries
    id value = [self getPreference:key from:pref];
    if (!value) {
        NSLog(@"[PLPreferences] Migrator could not find preference %@", key);
    }
    return value;
}

- (id)initWithGlobalPath:(NSString *)path {
    self = [super init];
    self.globalPath = path;
    self.globalPref = [NSMutableDictionary dictionaryWithContentsOfFile:path];
    [self saveGlobalPref];
    return self;
}

- (id)initWithAutomaticMigrator {
    self = [super init];
    self.globalPath = [@(getenv("POJAV_HOME")) stringByAppendingPathComponent:@"launcher_preferences_v2.plist"];
    NSMutableDictionary *pref = [NSMutableDictionary dictionaryWithContentsOfFile:self.globalPath];

    NSString *oldPath = [@(getenv("POJAV_HOME")) stringByAppendingPathComponent:@"launcher_preferences.plist"];
    NSMutableDictionary *oldPref = [NSMutableDictionary dictionaryWithContentsOfFile:oldPath];

    if (pref || !oldPref[@"env_vars"]) {
        // Initialize or load existing v2 layout
        self.globalPref = pref;
    } else {
        NSDebugLog(@"[PLPreferences] Migrating to %@", self.globalPath.lastPathComponent);
        // Perform migration from v1 layout
        self.globalPref = [NSMutableDictionary new];
        for (NSString *section in self.globalPref.allKeys) {
            for (NSString *key in self.globalPref[section].allKeys) {
                id value = [PLPreferences getOldLayoutPreference:key from:oldPref];
                if (value) {
                    self.globalPref[section][key] = value;
                }
            }
        }
    }

    [self saveGlobalPref];
    return self;
}

- (id)setDefaultsForPref:(NSMutableDictionary *)pref global:(BOOL)global {
    NSMutableDictionary<NSString *, NSMutableDictionary *> *defaults = [PLPreferences defaultPrefForGlobal:global];
    if (!pref) {
        NSLog(@"[PLPreferences] Initializing default values for %@ preferences", global ? @"global" : @"isolated");
        return defaults;
    }

    for (NSString *section in defaults.allKeys) {
        if (!pref[section]) {
            NSDebugLog(@"[PLPreferences] Set default values for section %@", section);
            pref[section] = defaults[section];
            continue;
        }
        // 关键修复：从 plist 加载的嵌套字典是不可变 NSDictionary（NSMutableDictionary
        // dictionaryWithContentsOfFile: 只保证顶层可变，嵌套字典仍为 NSDictionary）。
        // 如果不转为 NSMutableDictionary，后续 setValue:forKeyPath: 调用会抛出异常，
        // 导致用户修改的设置无法保存（mobileglues、video 等所有 section 均受影响）。
        if (![pref[section] isKindOfClass:[NSMutableDictionary class]]) {
            pref[section] = [pref[section] mutableCopy];
        }
        for (NSString *key in defaults[section].allKeys) {
            if (pref[section][key]) continue;
            id value = defaults[section][key];
            NSDebugLog(@"[PLPreferences] Set default vaule: %@", key, value);
            pref[section][key] = value;
        }
    }
    return pref;
}

- (void)setGlobalPref:(NSMutableDictionary *)pref {
    _globalPref = [self setDefaultsForPref:pref global:YES];
}

- (void)setInstancePref:(NSMutableDictionary *)pref {
    _instancePref = [self setDefaultsForPref:pref global:NO];
}

- (void)toggleIsolationForced:(BOOL)force {
    NSMutableDictionary *instancePref = [NSMutableDictionary dictionaryWithContentsOfFile:self.instancePath];
    if (force || [instancePref[@"internal"][@"isolated"] boolValue]) {
        NSLog(@"[PLPreferences] Using isolated preferences from %@", self.instancePath.stringByResolvingSymlinksInPath);
        self.instancePref = instancePref;
        if (!instancePref) {
            // Copy preferences from the global one
            for (NSString *section in self.instancePref) {
                for (NSString *key in self.instancePref[section].allKeys) {
                    self.instancePref[section][key] = self.globalPref[section][key];
                }
            }
        }

        // Declare that itself is isolated
        self.instancePref[@"internal"][@"isolated"] = @YES;

        [self saveInstancePref];
    } else if (self.instancePref) {
        NSLog(@"[PLPreferences] Using global preferences");
        _instancePref = nil;
    }
}

// ★ Task239（装机日志 4db827cf：全部游戏启动崩溃）：valueForKeyPath: 在
//   中间一跳落到【非字典】（标量/布尔/数组）时会对它继续 KVC 取下一键 →
//   NSUnknownKeyException 直接炸进程（Task238 的 game.gear.docked.left 踩中：
//   game→gear→docked(布尔)→left）。本类偏好键全部是"点分字典路径"语义，
//   逐跳 objectForKey: 行走 + 每跳校验 NSDictionary，等价于健康路径上的
//   valueForKeyPath:，病态路径返回 nil（= 键不存在，走 Getter/Setter
//   "could not find" 的既有回退链），从此这一整类崩溃被构造性根除
//   （Task142/143 "只能读写已注册键"家族的最后一颗雷）。
static id Ame239_SafeValueForPath(NSString *key, NSDictionary *root) {
    if (key.length == 0 || ![root isKindOfClass:[NSDictionary class]]) return nil;
    NSArray *comps = [key componentsSeparatedByString:@"."];
    if (comps.count == 0) return nil;
    id current = root;
    for (NSString *hop in comps) {
        if (![current isKindOfClass:[NSDictionary class]]) return nil;
        current = ((NSDictionary *)current)[hop];
        if (current == nil) return nil;
    }
    return current;
}

- (id)getObject:(NSString *)key {
    // Task239：安全行走替换 valueForKeyPath:（中间跳非字典 = nil，不再炸）
    id value = Ame239_SafeValueForPath(key, self.instancePref);
    if (!value) {
        value = Ame239_SafeValueForPath(key, self.globalPref);
    }
    if (!value) {
        NSLog(@"[PLPreferences] Getter could not find preference %@", key);
    }
    return value;
}

- (BOOL)setObject:(NSString *)key value:(id)value {
    // Task239：存在性检查改安全行走（原 valueForKeyPath: 会因中间跳落到
    // 布尔/标量而抛 NSUnknownKeyException——写入路径的同类崩溃源）。
    if (Ame239_SafeValueForPath(key, self.instancePref)) {
        @try {
            [self.instancePref setValue:value forKeyPath:key];
        } @catch (NSException *ame239_e) {
            NSLog(@"[PLPreferences] Task239 instance write guarded (%@: %@)", key, ame239_e.name);
            return NO;
        }
        [self saveInstancePref];
        return YES;
    } else if (Ame239_SafeValueForPath(key, self.globalPref)) {
        @try {
            [self.globalPref setValue:value forKeyPath:key];
        } @catch (NSException *ame239_e) {
            NSLog(@"[PLPreferences] Task239 global write guarded (%@: %@)", key, ame239_e.name);
            return NO;
        }
        [self saveGlobalPref];
        return YES;
    }
    NSLog(@"[PLPreferences] Setter could not find preference %@", key);
    return NO;
}

- (void)reset {
    if (self.instancePref) {
        [NSFileManager.defaultManager removeItemAtPath:self.instancePath error:nil];
        [self toggleIsolationForced:YES];
        // Only reset isolated values
        return;
    }

    self.globalPref = nil;
    [self saveGlobalPref];
}

- (void)saveGlobalPref {
    [self.globalPref writeToFile:self.globalPath atomically:YES];
}

- (void)saveInstancePref {
    [self.instancePref writeToFile:self.instancePath atomically:YES];
}

// 下载源管理（按类型独立持久化）
+ (NSString *)currentDownloadSourceForType:(NSString *)type {
    NSString *key = [self downloadSourceKeyForType:type];
    NSString *source = getPrefObject(key);
    return source ?: @"modrinth";
}

+ (void)setDownloadSource:(NSString *)source forType:(NSString *)type {
    NSString *key = [self downloadSourceKeyForType:type];
    setPrefObject(key, source);
}

+ (NSString *)downloadSourceKeyForType:(NSString *)type {
    if ([type isEqualToString:@"mod"]) return PREF_DOWNLOAD_SOURCE_MOD;
    if ([type isEqualToString:@"shader"]) return PREF_DOWNLOAD_SOURCE_SHADER;
    if ([type isEqualToString:@"resourcepack"]) return PREF_DOWNLOAD_SOURCE_RESOURCEPACK;
    if ([type isEqualToString:@"datapack"]) return PREF_DOWNLOAD_SOURCE_DATAPACK;
    if ([type isEqualToString:@"modpack"]) return PREF_DOWNLOAD_SOURCE_MODPACK;
    if ([type isEqualToString:@"world"]) return PREF_DOWNLOAD_SOURCE_WORLD;
    if ([type isEqualToString:@"server"]) return PREF_DOWNLOAD_SOURCE_SERVER;
    return PREF_DOWNLOAD_SOURCE_MOD;
}

// CurseForge API Key（运行时配置，覆盖编译时默认值）
+ (NSString *)curseForgeAPIKey {
    return getPrefObject(PREF_CURSEFORGE_API_KEY);
}

+ (void)setCurseForgeAPIKey:(NSString *)key {
    if (key && key.length > 0) {
        setPrefObject(PREF_CURSEFORGE_API_KEY, key);
    } else {
        // 注意：传 nil 会被 setValue:forKeyPath: 当作 remove，导致下次再写时
        // setObject:value: 因键不存在而静默失败。这里改写为空串以保留键。
        setPrefObject(PREF_CURSEFORGE_API_KEY, @"");
    }
}

// Mod 更新旧文件保留（默认 YES）
+ (BOOL)modUpdateKeepOld {
    NSNumber *value = getPrefObject(PREF_MOD_UPDATE_KEEP_OLD);
    return value ? value.boolValue : YES;
}

+ (void)setModUpdateKeepOld:(BOOL)keepOld {
    setPrefObject(PREF_MOD_UPDATE_KEEP_OLD, @(keepOld));
}

@end
