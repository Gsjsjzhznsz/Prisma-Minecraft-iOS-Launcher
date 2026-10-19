# Worklog

---
Task ID: 1
Agent: main (Super Z)
Task: 克隆 Prisma-Minecraft-iOS-Launcher 并完成项目盘点

Work Log:
- 克隆 https://github.com/Gsjsjzhznsz/Prisma-Minecraft-iOS-Launcher 到 /home/z/my-project/repo-prisma
- 盘点：PojavLauncher_iOS → Amethyst-iOS-MyRemastered → Prisma 谱系的 Fork；ObjC 为主，Min iOS 14
- 第一方代码：248 个 C/ObjC 文件约 16.6 万行（Natives/ 根 + installer + AI + authenticator + ctxbridges + input + TouchController + terracotta）、76 个 Java 文件（JavaApp/src）、200+ Python 任务脚本（scripts/）
- 第三方 vendored：Natives/external（MobileGlues、AFNetworking、ZeroTier 等，1.2 万文件）、ThirdParty/（ZalithLauncher2 参考、gl4es）
- 工程化线索：单一 workflow（development.yml）、54KB Makefile、worklog.md 388KB + worklog-archive.md 358KB 入库、lwjgl.jar 9.9MB 入库、announcements.json/help-faq.json 入库
- 用户需求：对话内输出团队评审风格报告，逐文件详查，覆盖架构/性能/功能兼容/工程化，关键问题带代码，附 P0/P1/P2 路线图

Stage Summary:
- 仓库就绪于 /home/z/my-project/repo-prisma，进入 6 路并行逐模块代码审查（Task 2-a ~ 2-f）

---
Task ID: 2-a
Agent: Explore(核心原生层)
范围：Natives/ 核心原生层 31 个第一方文件（main.m / JavaLauncher / utils / environ.h / non_darwin_utils / egl_bridge / input_bridge_v3 / ios_uikit_bridge / main_hook / sdl3_hook / dyld_patch_platform / dyld_bypass_validation / glfw_keycodes.h / shaderc_shim / shaderc_sandbox / shaderc_include / shaderc_impl_glue / spvc_shim / openal_shim / mithril_gl_shim / ZinkConfig / MurmurHash2 / SSZipArchive / ScreenUtils / jni.h），约 2.7 万行，逐文件审查（内存/JNI/线程/错误处理/健壮性/性能/安全七维）。

## 1) 逐文件问题清单

### P1（4 条）
1.【P1】utils.m:925-933 `DeviceHasTXMReal()` —— `char txmPath[PATH_MAX]` 仅在遍历到 96 字符目录名时被 snprintf 初始化；`/private/preboot` 打开成功但**无任何 96 字符条目**时（iOS 小版本变更/目录布局差异），`access(txmPath, F_OK)` 读未初始化栈内存 → 未定义行为，可能误判 TXM 有无，直接改变 JIT 路径选择（redirectFunctionMirrored/HWBreakpoint/Direct 三分叉）。
   修前：`char txmPath[PATH_MAX]; while(readdir){ if(len==96){snprintf;break;} } closedir; return access(txmPath,F_OK)==0;`
   修后：`char txmPath[PATH_MAX] = "/private/preboot"; BOOL found=NO; ... if(len==96){snprintf;found=YES;break;} ... return found && access(txmPath,F_OK)==0;`

2.【P1】main.m:225-300 `init_redirectStdio` 日志读取线程 —— `while(YES)` 无限循环体内无 @autoreleasepool；每次迭代创建大量 autoreleased 对象（`@(buf)`、componentsSeparatedByString 的数组+行、dataWithBytes、appendToLog 链）。libdispatch 只在 block 退出时 drain pool，而该 block 永不退出 → 整个进程生命周期内单调增长；MC 加载期日志速率高，长会话可泄漏数百 MB。
   修后：在 `while (YES) { @autoreleasepool { ...原循环体... } }` 包裹。

3.【P1】input_bridge_v3.m:789-847 `openURLGlobal` —— `dispatch_group_wait(group, DISPATCH_TIME_FOREVER)` 阻塞 Java "open" 调用线程；且 file 分支 `processPath` 拼出 `shareddocuments://<未编码路径>`，路径含空格/中文时 `[NSURL URLWithString:]` 返回 nil → `[UIApplication openURL:nil]` 抛 NSInvalidArgumentException → 主线程未捕获异常 → 整个 app 死亡（游戏目录名带空格即可触发）。同时 http/目录分支若 present 抛异常（虽有 @try 包裹目录分支）group 永不 leave = 永久挂起。
   建议：leave 收进 `dispatch_block_t` 保证（defer 语义）+ 路径先 `stringByAddingPercentEncodingWithAllowedCharacters:pathAllowedCharacterSet` 再拼 scheme；`DISPATCH_TIME_FOREVER` 改 10s 超时。

4.【P1】JavaLauncher.m:3187-3189 / 3230-3232 `launchHeadlessJVM` —— `while (!isJITEnabled(NO)) usleep(200ms)` 与 `while (!JIT26IsLikelyDebuggerKeepAttached())` 两个**无超时死循环**。Task169 已在游戏启动链把同款裸循环替换为有界 `ame169_waitForJITCondition`（病历：stikjit:// 偶发失败 = 永久卡死），headless 路径漏改 → Forge/NeoForge 安装线程可永久挂起。另 `dispatch_sync(main_queue)`（3132/3217）在主线程被占时有死锁风险。
   建议：两处循环改 `ame169_waitForJITCondition(..., 120, @"headless-jit")`；dispatch_sync 改 dispatch_async + 信号量。

### P2（安全/健壮性，按文件）
5.【P2·安全】JavaLauncher.m:650-662 `ame225_healMissingAssets` —— `rel = assets/objects/<hash前2字符>/<hash>`，hash 直接来自 assets index JSON 且仅校验 `length>=4`；恶意/损坏 index 中 `hash="../../../../tmp/evil"` 可使 rel 路径穿越 gameRoot，配合官方资源服 URL 拼接实现**任意路径写**（组合 `../` 前缀）。修后：`NSCharacterSet hexCharacterSet` 校验 hash 全为 [0-9a-f]（20/40 位）再参与拼路径。
6.【P2】JavaLauncher.m:1758 `JIT26SendJITScript([NSString stringWithContentsOfFile:...])` 无 nil 检查（headless 路径 3261-3267 已做 N5 修复，游戏路径漏改）；nil → `UTF8String`=NULL 传入 brk ABI。
7.【P2】JavaLauncher.m:1209-1231 `ame158_fetchSynchronous` —— 每次调用新建 NSURLSession 从不 invalidate；50s 信号量超时后 `[task cancel]` 返回，completion handler 仍可能并发写 `__block ame158_result`（数据竞争）；timeoutIntervalForRequest(20) < resource(45) < 等待(50) 三值关系混乱。
8.【P2】JavaLauncher.m:818 / 1549-1554 等 —— `stringWithFormat:localize(...)` 把本地化串当格式串；译文含 `%` 即崩溃/串坏。应统一 `stringByAppendingFormat` 或转义。
9.【P2】JavaLauncher.h:18 `JLI_Launch_func *pJLI_Launch;`、utils.h:181 `BOOL debugLogEnabled, isJailbroken;`、ios_uikit_bridge.h:8 `UIViewController* tmpRootVC;` —— 头文件里的**全局变量定义**（-fcommon tentative def 兜底）。项目注释已两次记录该模式在 C++ TU 炸 duplicate symbol（Task83/Task122），这三处是同类未爆雷。应改 `extern` + 单一定义 TU。
10.【P2】main.m —— ① init_checkForsubstrated 所有路径均不 free(process)（kinfo_proc 全进程表泄漏，一次性）；② latestlog 轮换块 tailStr 泄漏；③ NSLog(@"Version: %@", ..., CONFIG_TYPE) 多余实参；④ `pipe(pfd)` 返回值未查；⑤ init_setupHomeDirectory `realpath()` 可 NULL 传入 setenv。
11.【P2】main.m:292-293 —— 日志线程每 2KB chunk `[file synchronizeFile]`（逐块 fsync 级刷盘），加载期数千次同步 I/O；可改 8s 定期/退出时同步。
12.【P2】utils.m:703-755 `localize()` —— 每次调用 getPrefObject + pathForResource/bundleWithPath（NSBundle 内部有缓存但查找仍有成本），UI 构建期大量调用；`NSLocale.preferredLanguages[0]` 无空数组防护。建议缓存语言 bundle + 首选语言快照。
13.【P2】egl_bridge.m:657 `strcmp(getenv("AMETHYST_RENDERER"), "auto")` 无 NULL 守卫（env 未导出时 pojavSetWindowHint 提前被调 = NULL 解引用）。
14.【P2】input_bridge_v3.m:1033-1048 `JNI_OnLoad` GetEnv 返回值未查，失败时 env 为栈垃圾传给 registerOpenHandler。
15.【P2】input_bridge_v3.m:2155 `keyDownBuffer[MAX(0,key-31)]` 无 NULL/越界防护（POJAV_SKIP_JNI_GLFW 时 keyDownBuffer=NULL，LWJGL 回调仍可能注册成功 → NULL+offset 写）。
16.【P2】input_bridge_v3.m:897-913 `CTCClipboard_nQuerySystemClipboard` —— GetStaticMethodID 失败时 global ref 已建 + 异常未 clear，下轮调用重复 NewGlobalRef（泄漏）；dispatch 块内 runtimeJavaVMPtr 无 NULL 守卫。
17.【P2】input_bridge_v3.m:1139-1177/1204-1228 事件队列协议 —— pump 读 counter→处理[0,counter)→**回存旧 counter**（依赖 Java 侧 pojavRewindEvents 归零）；与并发 sendData 存在丢事件/回滚窗口（上游继承设计，症状罕见但值得注释化+文档）。
18.【P2】ios_uikit_bridge.m:15-176 四个弹窗函数（internal_showDialog / ame187 / ame173 / showError 无此问题）—— handler block 强引用 alert（objc_getAssociatedObject(alert,...)），UIAlertAction 被 alert 持有 → **alert→action→block→alert 保留环**，每次弹窗泄漏 alert+level1000 window；Task126 只修了 window 归还，环未断。修后：block 内用 `__weak UIAlertController *weakAlert = alert`。
19.【P2】main_hook.m:908-977 `retryPipelineWithSIntFormats` / `createPipelinesWithAlignedStrides` —— 全部 malloc/calloc 未查 NULL（OOM 时 memcpy(NULL,...) 必崩），与同文件其余路径的防御水准不符。
20.【P2】main_hook.m:1556-1566 `ame_run_on_32mb_stack` —— 每次 shaderc/spvc 编译 pthread_create+join（一次会话数百次）；建议线程池或 pthread key 复用（正常路径已被 fork-server 沙箱接管，仅降级路径暴露）。
21.【P2】dyld_bypass_validation.m:70-94 `redirectFunctionMirrored` —— 镜像按 sizeof(patch)=24B remap（页粒度 1 页）；patchAddr 距页尾 <24B 时 memcpy 越过镜像映射尾（理论 UB，概率极低）。
22.【P2】sdl3_hook.m:1172-1204 `ame_SDL_GL_GetProcAddress` 尾部回落 `dlsym(RTLD_DEFAULT, proc)` —— 渲染器未导出的 gl*/egl* 名会命中**系统 /usr/lib/libGLESv2**，正是 Task204 定性的"符号劫持"通道（ANGLE 会话缺名时拿到无上下文死指针）。建议 gl* 前缀不回落 RTLD_DEFAULT（与 ame204_gl4esProcResolver 同口径）。
23.【P2】sdl3_hook.m:1237-1251 `ame_SDL_ShowWindow` 非主线程 dispatch_sync(main)；主线程若等待渲染线程即死锁（注释已论证主线程空闲假设，建议加注释外的超时或断言）。ame_primaryWindow/refs 无锁（单窗假设）。
24.【P2】SSZipArchive.m（路径穿越专项）—— ① `_sanitizedPath`（1453）正确中和 `../`/反斜杠/百分号歧义 ✓；② 符号链接逃逸守卫（689 `_escapesTargetDirectory`，CVE-2022-36943 对策）**仅当调用方传 symlinksValidWithin 才激活**：300-321 的 nestedZip 便捷入口传 destination ✓，但 235-299 的 8 个旧便捷入口（delegate:/progressHandler:/overwrite:password: 等）全部传 nil → 走这些入口时"zip 内 symlink 指向目录外 + 后续文件条目写穿 symlink"的逃逸面重新打开。建议所有便捷入口默认 `symlinksValidWithin:destination`；③ `filenameIsDirectory` 读 `filename[size-1]`，size_filename==0 时 OOB 读 1 字节。
25.【P2】JavaLauncher.m:672-705 `ame225_healMissingAssets` —— `NSData dataWithContentsOfURL` 无显式超时（默认 60s/请求），20s 预算只在每文件开始前检查，单个坏网络文件可阻塞远超预算（游戏启动路径上）。

### P3（次要/代码卫生）
26.【P3】utils.h:363 `attachThread()` 声明在 Natives 内无定义、无调用者（死声明）。
27.【P3】utils.m:258 `ame185_gameCandidates_PLACEHOLDER` 命名欠账；utils.m:887-896 DeviceCanCreateRXMap 连续两次相同 mprotect 按 OR 合并（冗余调用）；utils.m:882-885 JIT26SendJITScript 传 script.length（UTF-16 单元数）当字节长度（非 ASCII 脚本长度失真）。
28.【P3】input_bridge_v3.m ame82 文本环 idx/ame82_pendingHighSurrogate 无锁（多 UI 线程路径，实际单写者）；mcscale() 的 resolutionScale=0 除零→inf→强转垃圾；touchHotbar hotbarKeys 索引 FP 舍入到 9 的理论越界。
29.【P3】egl_bridge.m clientAPI/ame_brLastCurrent 跨线程裸 int/指针（良性，建议 atomic 化）；ame208/ame211 boot 双检无锁（gl4es 侧幂等兜底）。
30.【P3】openal_shim.c:106-129 注释称"全局/设备级各自组合，不共用缓存"，实现实际共用单一 ame129_ext_buf（后者覆盖前者）；LWJGL 即取即用故无症状。
31.【P3】shaderc_shim.c:1361-1363 malloc 失败的静态 fake result 会被后续复用覆盖 message（取证信息失真）；s_storm 统计只在崩溃分支末尾打印。
32.【P3】MurmurHash2.m 逐字节 ShouldSkipByte + 两遍全文扫描（大 jar 慢，离线场景可接受）；NSInputStream streamError 判定依赖实现。
33.【P3】dyld_patch_platform.m:124 `segname[0]=='_' &&` 冗余；hooked_open（main_hook.m:2071）无条件 va_arg 读取（O_CREAT 缺席时 UB，实践无害）。
34.【P3】jni.h / glfw_keycodes.h 为 AOSP/GLFW 上游 vendored 头，无问题。

## 2) 模块级架构观察
- **环境变量即 IPC**：AMETHYST_RENDERER/GRAPHICS_API/POJAV_DISABLE_VSYNC/MOBILEGL_* 等十几个 env 是模块间事实契约，同一逻辑在 JavaLauncher 与 egl_bridge 双写（MOBILEGL_ESPRYT_MULTIDRAW_MODE、-gles→物理库名映射——后者已用 ame_physical_renderer_dylib 收敛 ✓，前者仍是双份）。建议建"env 写入点注册表"单一出口。
- **launchJVM 神函数**：~700 行混合 JIT 编排/渲染器解析/classpath 组装/UI 弹窗/CWD 对齐；headless 变体复制 ~300 行（PUSH_HARGV 宏与 retainedStrings 模式重复）。PUSH_MARGV 宏 + retainedStrings 是正确的悬垂修复，但两份拷贝注定漂移。
- **四层 hook 叠加**（fishhook 全进程 dlsym/dlopen/exit/abort/open → Task132/133 GOT 直改 → sdl3_hook 按名接管 → ame204/202 符号钉扎）：每层都有逃生阀 env 和幂等设计，工程纪律好；但跨层不变量（谁最后拥有 dlsym）只存在于注释中，新人极易破坏。建议一张 hook 拓扑图入 docs。
- **environ.h 全局变量海**（eventCounter/events[8000]/cursor*/windowWidth... 混合 C/C++ extern 声明）是输入/渲染/UI 三域的共享黑板，竞态面集中于此；Task83/122 的 AME_ENVIRON_DECL 机制说明该文件是链接事故高发区。
- **注释密度与"病历"文化**极高质量，但 JavaLauncher.m/sdl3_hook.m/input_bridge_v3.m 的 50-150 行事故叙事内嵌函数头，检索成本高——建议沉淀到 docs/incidents 并保留一行指针。

## 3) 值得肯定的设计亮点
- **shaderc 防御栈（shim/sandbox/include/glue/cache）是本仓库的工程巅峰**：递归主锁跨库协商（shaderc/spvc/MG 三引擎全串行）、fake-result 防 NULL→NPE、SIGSEGV 网.siglongjmp 恢复、glslang 进程态重建、fork-server 进程外编译（fork 时机选择的三条理由论证）、SPIR-V 磁盘缓存跨启动单调固化、#include 展开带 #line 恢复与 Task103 换行修补——层层降级永不劣化现状。
- main.m Task27/171/43：日志管道丢尾取证、crash log 保全、fork 时机与锁持有的推理链——运维级思维。
- Task223 渲染线程驻车（pthread cond 在交换边界 park）是标准的生命周期-渲染线程解耦做法，死锁分析到位。
- Task185 自愈式主队列派发、Task169 有界 JIT 等待、Task188 目录自愈、Task141/173 内存双闸（Xmx 与 Jetsam 同源钳制）——把装机病历变成结构修复的闭环非常好。
- egl_bridge Task204 用二进制布局指纹 + resolver 注入根治系统 GLESv2 符号劫持；Task219 virgl 引导失败优雅降级 zink。
- 大量关键路径有限频日志、幂等标记文件、逃生阀 env（AMETHYST_*_OFF/=0），可回滚性意识贯穿始终。

## 4) 审查文件清单
完整读完（逐行）：main.m、non_darwin_utils.m、environ.h、utils.h、utils.m、JavaLauncher.h、JavaLauncher.m、egl_bridge.m、input_bridge_v3.m、ios_uikit_bridge.m、ios_uikit_bridge.h、main_hook.m、sdl3_hook.m、dyld_patch_platform.m、dyld_bypass_validation.m、shaderc_shim.c、shaderc_sandbox.m、shaderc_sandbox.h、shaderc_include.c、openal_shim.c、mithril_gl_shim.c、MurmurHash2.m、ScreenUtils.m、SSZipArchive.m（重点段：sanitize/symlink/主解压循环逐行，zip 写入段抽查）、jni.h（标准 AOSP 头，抽查）。
抽查（结构+关键函数）：shaderc_impl_glue.c（头部 ABI 约定+类型段）、spvc_shim.c（注册表/锁协商/ES 重写段，入口锁点全 grep 验证）、ZinkConfig.m（设备表+环境导出段）、glfw_keycodes.h（vendored 标准头）。
JNI 专项核对：runtimeJavaVMPtr/JNIEnv 获取模式（GetEnv→Attach→Detach）在 JNI_LWJGL_changeRenderer ✓、CallbackBridge_syncModifiersToMC ✓、CTCClipboard ✗(P2#16)、JNI_OnLoad ✗(P2#14)；GlobalRef 管理：vmGlfwClass ✓、class_CTCClipboard ✗(P2#16)；LocalRef：ChangeRenderer 显式 Delete ✓、syncModifiers ✓；异常检查：registerOpenHandler/hooked_isAlive0 ✓，CallStaticVoid 后多数缺 ExceptionCheck（pending exception 透传风险，P3）。

结论：无 P0（未发现必然崩溃/必然泄漏的主路径缺陷）；P1×4 建议本轮修复（TXM 误判、日志线程泄漏、openURL 崩溃+挂起、headless 死等）；P2×21 按渲染器会话影响排序入库；整体代码质量显著高于同体量 fork 项目，防御性工程是最大资产，主要债务在头文件全局定义、双写逻辑与神函数。

---
Task ID: 2-b
Agent: Explore(游戏UI层)
Task: 审查游戏 UI 与界面层（Natives/ 第一方 UI/游戏交互文件，只读）

## 1. 逐文件问题清单

### P0（构建/崩溃级）

1. 【P0】Natives/LauncherCardLayoutViewController.m:47 — 源码损坏，语法错误，构建必败。
   该文件已列入 CMakeLists.txt:537 构建清单，且 SceneDelegate 默认根 VC 即 Card 布局，HEAD 无法编译。
   ```objc
   // 修改前（损坏，缺 "[m" 三个字符）：
   return odel containsString:@"iphone"];
   // 修改后：
   return [model containsString:@"iphone"];
   ```
   建议顺手全库扫一遍同类缺字符损坏（本文件仅此一处）。

### P1（泄漏/崩溃风险/功能性缺陷）

2. 【P1】SurfaceViewController.m:1253-1258 + 3680-3683 — NSTimer target:self 循环强引用，VC 永不释放。
   statsTimer（1s 采样）与 launchStageTimer（0.5s，:2168）均 target:self，invalidate 只写在 dealloc；
   而 timer→runloop→timer→self 的强链使 dealloc 永远不可达。连带后果：整个视图树、GameSurfaceView
   （CAMetalLayer drawable 显存）、5 个块式通知观察者全部滞留；多轮"进出游戏"后泄漏叠加，
   直接加剧 jetsam（本 App 还刻意抬高 jetsam 上限运行 MC）。
   ```objc
   // 修改前：
   self.statsTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self
       selector:@selector(updateGameStats) userInfo:nil repeats:YES];
   // 修改后（block + weak，或退出游戏时显式 invalidate）：
   __weak typeof(self) weakSelf = self;
   self.statsTimer = [NSTimer timerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
       [weakSelf updateGameStats];
   }];
   [[NSRunLoop currentRunLoop] addTimer:self.statsTimer forMode:NSRunLoopCommonModes];
   ```
   另 5 个块观察者（:1358/:1389/:1395/:1404/:1412）形成 self→token→block→self 自持环，
   注释自称"关键修复"，但只是把 token 存属性——仍依赖 dealloc 打破，而 dealloc 被 timer 环堵死，修复不完整。

3. 【P1】SurfaceViewController.m:2498-2533 vs SurfaceViewController+Navigation.m:352-360 — 游戏内菜单"键盘开关"与键盘守望状态机打架。
   actionToggleKeyboard 直接 resignFirstResponder，不递增 ame171_keyboardDismissGeneration、不经
   ame225_resignInputTextField 包夹；Task224 常驻守望 0.4s 后见 !isFirstResponder 会自愈重挂
   （预算 10 次）= 用户刚从菜单关掉的键盘被反复弹起。且 become 前未写哨兵空格（Task171 明载的
   旧序病灶）。修改：与主文件所有显式收起点同路径（++generation → ame225_resignInputTextField）。

4. 【P1】input/ControllerInput.m:43-57 — `int keycode;` 未初始化，映射未命中时把栈垃圾发给 MC。
   ```objc
   // 修改前：
   int keycode;
   ...
   switch (keycode) { ... default: CallbackBridge_nativeSendKey(keycode, 0, pressed, 0); }
   // 修改后：
   int keycode = GLFW_KEY_UNKNOWN;   // 未命中 → case GLFW_KEY_UNKNOWN: do nothing
   ```

5. 【P1】LauncherNavigationController.m:615-660 — observeValueForKeyPath 中整数除零 + static 竞态。
   `progress.estimatedTimeRemaining = @((totalUnitCount - completedUnitCount) / throughput);`
   当某秒进度零增长（网络 stall/解压段）throughput==0 → SIGFPE 崩溃；lastMsTime/lastSecTime/
   lastCompletedUnitCount 为文件级 static，KVO 回调线程不定 → 数据竞争。修改：除前判 0，
   状态收进实例 ivar。
   另 :1009-1013 viewDidLayoutSubviews 每次布局 post "UpdateAccountInfo" → 布局风暴
   （滚动/旋转期间每帧触发 RightPanel.updateAccountInfo 头像链 + updateVersionInfo），主线程抖动源。
   修改：账户变化处或 viewDidAppear 时刷新。

6. 【P1】SurfaceViewController.m 触摸坐标系/比例因子混用 — 外接屏与 hotbar 命中隐患。
   - touchesBegan:3449-3452 用 self.rootView 算 hotbar 坐标，而 Task59 注释（:2635-2640）已定性
     rootView 宽 +30pt 引入 +15pt 恒定水平偏移并把 sendTouchEvent 改用 surfaceView 参考系——
     hotbar 主判定却仍在 rootView 口径；surfaceOnDoubleClick:2785、surfaceOnLongpress:2823、
     surfaceOnHover:2797 同用 rootView。sendTouchEvent 的 MOVE delta 又混用
     previousLocationInView:rootView 与 locationInView:surfaceView（:2676-2678，常量偏移可抵消但口径脏）。
   - :2657/:2784/:2824/:3450 用 [[UIScreen mainScreen] scale]，:2420/:1784 用 self.screenScale
     （scene 侧）——AirPlay 外接屏时 mainScreen 是机内屏，hotbar/双击命中错位。
   修改：统一 surfaceView 参考系 + self.screenScale 单一来源。

7. 【P1】input_bridge_v3.m:1204-1228 — 无锁多生产者事件队列丢事件。
   sendData/sendDataFloat 读 eventCounter→写槽→store release；触摸（主线程）、GC 手柄回调
   （GC 内部队）、陀螺仪/手柄 tick（displayLink 主线程）并发时可同槽互覆；消费者
   pojavPumpEvents（MC 线程）无 per-slot 同步。上游遗产设计，低概率难复现"输入偶尔丢"。
   修改：至少加自旋锁/串行队列，或迁移到 OS_dispatch_queue 重放。

8. 【P1】SceneDelegate.m:274-286 — applyLanguageChange 无 isRunning 守卫。
   游戏中（rootViewController==SurfaceViewController）在设置里切语言会用 LauncherRoot/CardLayout
   替换 window.rootViewController，摧毁进行中的游戏会话。修改：`if (SurfaceViewController.isRunning) return;`（或仅记偏好待回启动器生效）。

9. 【P1】PLLogOutputView.m:153-178 — 暂停按钮无效 + 日志无上限。
   `_appendToLog` 从不检查 canAppendToLog（:52/:119 的 toggle 无人消费）→ "暂停日志"按钮形同虚设；
   logLines 静态数组随 JVM 全量日志无限增长 + 逐行 insertRows，长会话内存/滚动性能双退化。
   修改：入口判 canAppendToLog；加环形上限（如 2000 行）。

### P2（质量/健壮性/性能）

10. 【P2】SurfaceViewController.h:8-12 — 头文件里裸定义全局变量（canAppendToLog/fatalExitGroup/
    virtualMouseFrame/lastVirtualMousePoint），靠 CMakeLists.txt:14 的 `-fcommon` 合并符号；
    换 -fno-common（现代默认）即链接失败，且跨 5+ TU 隐式共享可变状态。修改：头文件 extern + 唯一定义 .m。
11. 【P2】SurfaceViewController.m:479-515 — TouchController 消息循环 60Hz 忙轮询（usleep 16ms）+
    每轮新建 NSMutableData + isViewDismissed 每轮 dispatch_sync(main)；建议 dispatch source/事件驱动。
12. 【P2】SurfaceViewController.m:1578-1583 — updateSavedResolution 遍历 connectedScenes 时每场景
    都写 self.screenScale、遇非 Application role 才 break，取值依赖 scene 顺序，外接屏时脆弱。
13. 【P2】SurfaceViewController.m:2355-2356 与 :2939 — `properties[@"keycodes"][i]` 0..3 直接下标，
    自定义布局 JSON 键位数不足即越界崩溃；建议 clamp+防御日志。
14. 【P2】SurfaceViewController.m:2927-2931 — s_ame176_modDownTime/s_ame179_toggledMods 为文件级
    static，跨游戏会话残留（上次会话 toggle 的 shift 态带入下次）；currentHotbarSlot、pojavWindow
    （dealloc 未清）同理。
15. 【P2】SurfaceViewController.m:3567-3568 — touchesCancelled 也走 touchesEndedGlobal 发 ACTION_UP，
    取消当抬起；长按被系统取消时游戏内仍收到完整点击，语义应为统一取消路径。
16. 【P2】SurfaceViewController.m:2684-2710 — pressesBegan/Ended 三路投递（KeyboardInput GLFW + 
    转发 SDL_uikitview + super）；touches 已注明不转发防双发，presses 转发在 26.2/26.3 双路径
    下的重复键风险需实测收敛。
17. 【P2】UIKit+hook.m:171-181 — UITraitCollection(hook) 直接 category 覆盖 horizontal/vertical
    SizeClass 恒 Regular（继承上游但影响全 App 系统控件布局）；:51 setImage: 全局 swizzle；
    :238-247 UIPointerInteraction 按 ivar offset 裸写内存，ivar 缺失时 offset=0 写到 isa 附近，需判空。
18. 【P2】SceneDelegate.m:51-73 FreezeWatch/ame192 异常处理器复挂定时器常驻后台（30s 心跳永不终止），
    低开销但建议游戏退出后降频/停止。
19. 【P2】SurfaceViewController+ExternalDisplay.m:17/:35 — noteLabel 重复添加（重复切换）与
    touchView.subviews[0] 硬编码索引取标签，脆弱；建议 tag 定位。
20. 【P2】SurfaceViewController.m 全文件 30+ 处注释 mojibake（"ç¼ç "/"æ¨¡å¼" 等，UTF-8 被二次
    编码的历史痕迹），可读性受损，建议一次性归一化。
21. 【P2】JavaGUIViewController.m:366-379 — 后台块强持 self 跑完 launchJVM 后直写 ivar
    `_requiredJavaVersion = 0`（线程不安全，虽然此时页面已在）；displayLink 线程修复本身是亮点。
22. 【P2】GyroInput.m:16 — `UIApplication.sharedApplication.windows[0]` 已废弃且取首窗，外接屏
    场景方向判错；建议 windowScene.interfaceOrientation（自视图）。
23. 【P2】SurfaceViewController.m:1468-1476 — MousePointerUpdated 每次通知都 imageWithContentsOfFile
    重新读盘；可缓存 UIImage。

## 2. SurfaceViewController 专项（上帝类评估）

- 规模：3733 行；文件内 93 个方法实现（分布在 4 个类：TouchSender、PLDisplayLinkTarget、
  Ame156TCIMEAwareTextField、SurfaceViewController 本体约 86 个）；平均方法长 39.6 行。
- 超长方法：>100 行 9 个，>50 行 20 个。Top：viewDidLoad 330 行（L1138-1467）、
  SDL 呈现执法区 265 行（L3148-3412，dump+Enforce）、setupLaunchOverlay 229 行（L1961-2189）、
  updateSavedResolution 156 行（L1577-1732）、executebtn: 151 行（L2899-3049）、
  PLDisplayLinkTarget 区 142 行、launchMinecraft 130 行、TouchController 编码区 126 行（L342-467）、
  processTouchControllerMessage 111 行（L908-1018）。
- 职责清单（15 项）：①视图/层级搭建 ②分辨率与 FSR/几何换算（windowWidth 信念、Task175 比例）
  ③JVM 启动管线+预检门（LTW 门、MSA 令牌门、jetsam）④启动遮罩 UI+阶段时间轴+取消
  ⑤触摸路由与 6 个手势处理器+hotbar ⑥虚拟鼠标 ⑦键盘会话治愈状态机（Task171/223/224/225）
  ⑧TouchController 全栈（UDP sender 类+静态库消息循环+8 种消息编解码+IME 字段+震动）
  ⑨手柄/鼠标/陀螺仪接入（GC 通知）⑩屏幕虚拟按钮 executebtn 家族+滑动换钮+Task179 修饰键 toggle
  ⑪SDL3 呈现面执法（黑盖子修复+z 序）⑫FPS/内存/帧间隔诊断 ⑬外接屏（分类）⑭日志面板（分类）
  ⑮音频会话/偏好应用。分类仅剥走菜单/日志/外接屏三块，其余仍在本体。
- 拆分建议（按耦合最小切口，本体可降到 <600 行）：
  1) TouchControllerCoordinator（⑧ 全部，约 900 行，独立 .m/.h，消息编解码用统一 writer）；
  2) LaunchFlowController + LaunchOverlayViewController（③④，约 500 行，遮罩本就是独立 UI）；
  3) SurfaceGeometry（② + Metal 层配置 + ame139/153/175，约 300 行纯函数化）；
  4) InputEventRouter（⑤⑥⑩，手势/触摸/hotbar/虚拟鼠标，约 700 行）；
  5) KeyboardSessionHealer（⑦，与 TrackedTextField 配套，约 250 行）；
  6) SDL3PresentationEnforcer（⑪，C 函数本就可独立文件）；
  7) GameStatsMonitor（⑫）。全局静态（pojavWindow/currentHotbarSlot/s_touchToFingerIdMap/
  ame179 toggle 表）随模块归位并加生命周期清理。

## 3. 模块级架构观察与重复代码

- 通知总线过载：LauncherRootViewController 注册 19 个通知、RightPanel 16 个、菜单/侧栏各若干；
  "UpdateAccountInfo" 从 viewDidLayoutSubviews 发出（见 P1-5）形成布局→通知→布局的潜在环。
  建议收敛为 2-3 个显式协调者（SidebarCoordinator/ContentCoordinator）或闭包回调。
- JIT 等待链整段重复：invokeAfterJITEnabled + ame172_reattachJIT26ThenLaunch + ame169 超时弹窗
  在 LauncherNavigationController.m（:693-947）与 LauncherRightPanelViewController.m（:1724-1900+）
  两份各约 200 行（注释互指"同 RightPanel"）。抽 JITEnableCoordinator 单点维护。
- 工具重复：colorFromHexString 在 LauncherRootViewController.m:854 与 LauncherMenuViewController.m:368
  两份实现；物理设备检测+侧栏/右栏宽度函数在 Root 与 CardLayout 两份（含 P0 损坏的那份）。
- 手写大端编码器 ×6（encodeAddPointer/RemovePointer/InputStatus/InputCursor/InputArea/Vibrate/
  MoveView/Capability）模式雷同，可用统一 appendBE32/appendBEFloat 助手收敛。
- 全局可变状态网络：SurfaceViewController.h 四全局 + prefDict + localVersionList/remoteVersionList
  + input_bridge_v3 的 isGrabbing/windowWidth（跨线程读写仅靠约定）。
- 注释文化是双刃剑：Task 病历式注释极佳（可取证），但 SurfaceViewController.m 内混编码 mojibake
  与大段历史病历使有效信噪比下降，建议"病历归档到 docs/，代码注释留一行链接"。

## 4. 设计亮点

- NMToast：代际令牌防旧定时器误关新 toast、弱静态 current、主线程安全——教科书级小组件。
- TouchController/ios_transport.c：双 ABI trampoline（指针注册表零解祖判别新旧 JNI 签名）+
  互斥完备 + 部分初始化回滚；ring_buffer 忠实移植并注明许可。工程质量高。
- GameMenuOverlayView：hitTest 定向穿透（仅按钮/标签拦截，其余透传游戏画面）+ 位置百分比持久化。
- GameSurfaceView.layerClass：以 ame_effective_renderer 单一事实源决定 CAMetalLayer/CALayer，
  附完整事故链注释（Task124）。
- SceneDelegate Task189/191 窗口旋转 shim：加速计驱动的 ±90°/180° 跟手，且留
  general.disable_window_rotation_shim 逃生舱。
- JavaGUIViewController：displayLink 线程泄漏的根修（NSThread+CFRunLoopStop）做得干净。
- TrackedTextField Task156 双路径去重（mach 毫秒时间戳 20ms 窗）兼顾 IME 兼容与连击。
- Task176 主线程看门狗、Task32/52 呈现面执法等"只取证不干预"的调试设施设计克制。

## 5. 审查文件清单

完整逐行读完（17 个）：
SurfaceViewController.h/.m、SurfaceViewController+Navigation.m、+LogView.m、+ExternalDisplay.m、
GameSurfaceView.m(.h 略)、GameMenuOverlayView.h/.m、UIKit+NativeSurface.m、UIKit+hook.m、
input/ControllerInput.m、input/GyroInput.m、input/KeyboardInput.m、AppDelegate.m、SceneDelegate.m、
SceneExternalDelegate.m、LauncherSplitViewController.m、LauncherMenuViewController.m、
PLLogOutputView.m、PLPickerView.m、PickTextField.m、ScreenUtils.m、UIViewController+AMEPanel.m、
TrackedTextField.m、TouchControllerBridge.m、TouchController/ring_buffer.c、NMToast.m（前 120 行精读+全文模式扫描）。

重点段落精读+全文模式扫描（10 个）：
input_bridge_v3.m（2407 行，精读 SDL3 事件结构/队列/pump/nativeSend* /grab 同步/AFK 心跳/键位
净化约 1400 行）、LauncherNavigationController.m（1015 行全读）、LauncherRootViewController.m
（1019 行全读）、LauncherCardLayoutViewController.m（头部+模式扫描，P0 定位）、
LauncherRightPanelViewController.m（2156 行，viewDidLoad/KVO/JIT 链/账户信息精读）、
WelcomeViewController.m（头部+模式扫描）、JavaGUIViewController.m（中段精读+模式扫描）、
PLCrashView.m（退出/重启路径模式扫描）、TouchControllerPreferencesViewController.m（模式扫描）、
LiquidGlassCompat.m（头部精读）、MarqueeLabel.m/InlineMessageView.m/Ame223CoachMarksView.m
（生命周期模式扫描）、TouchController/ios_transport.c（450/584 行精读）。

未覆盖（超范围，留待 2-x）：customcontrols/*、ctxbridges/*、installer/*、JavaApp/*。

## 结论摘要

P0×1（CardLayout 源码损坏、构建必败）、P1×8（statsTimer/launchStageTimer 循环强引用致 VC 级
泄漏、游戏内键盘开关与 Task224 守望冲突、手柄映射未初始化键码、KVO 整数除零+布局通知风暴、
hotbar/rootView 坐标系混用、input 队列无锁多生产者、切语言摧毁游戏会话、日志暂停失效+无上限），
P2×14。SurfaceViewController.m 确认为上帝类（3733 行/86 方法/9 个超百行方法/15 类职责），
已给 7 模块拆分方案。整体印象：底层交互工程（SDL3/TouchController/输入桥）质量高于 UI 层平均，
UI 层的主要债务是通知耦合、重复代码与生命周期纪律（timer/KVO/静态态）。

---
Task ID: 2-d
Agent: Explore(网络认证AI层)
范围：authenticator/（7 文件）+ 4 个账号 VC；联机全链（Terracotta*/Multiplayer*/LanPortDetector/PortForwarder/SOCKS5Proxy/ZeroTierBridge/terracotta.h）；AI 模块（Natives/AI/ 57 文件）；更新公告（UpdateChecker/Announcement*/MinecraftNews*/MarkdownParser）；杂项（Server*/SilentAudioPlayer/audio_capture_bridge/Bing*/Background*/HomeCustomize/ImageCropper/CustomIconManager/IconLoader）。
方法：只读审查。安全核心文件逐行读完（authenticator 全部、AiFileTools/AiAssetTools 关键路径/AiAPIClient/AiAgent/AiSafetyManager/AiProviderStore/AiSettingsTools/AiToolRegistry/AiInstanceCreator/AiDownloadProbe/AiToolBootstrapper、PortForwarder/SOCKS5Proxy/ZeroTierBridge/LanPortDetector/TerracottaBridge/MultiplayerManager 全文、MarkdownParser/UpdateChecker/AnnouncementService/MinecraftNewsService/AnnouncementItem 全文、BingWallpaperManager/CustomIconManager/AvatarManager/AccountLoginViewController 全文）；大 UI 文件（MultiplayerViewController/TerracottaViewController/AccountList/ThirdPartyLogin/BackgroundManager 等）通读逻辑分支 + 危险模式 grep 抽查；Info.plist ATS 配置核验。

## 一、安全风险汇总（P0/P1）

【P0】【Natives/AI/AiProviderStore.m:112-122 + AiProvider.m:62 + AIProviderConfigViewController.m:588】
AI 供应商 API Key 明文落盘 Documents/AI/providers.json（NSJSONSerialization 直接写 apiKey 字段，无 Keychain、无加密）。
修改前：provider.apiKey 随 toDictionary 进 JSON → writeToFile；沙盒备份/itunes 文件共享/iCloud 备份/容器文件系统取证均可直接读出。
修改后：apiKey 迁 iOS Keychain（kSecClassGenericPassword，Account 为 provider.identifier，kSecAttrAccessibleWhenUnlockedThisDeviceOnly），providers.json 只存 baseURL/model/temperature 等非敏感字段；读取时按 identifier 反查 Keychain。至少应在保存时对现网文件做一次剥离迁移。

【P0】【Natives/Info.plist:235-239】NSAppTransportSecurity = NSAllowsArbitraryLoads:true，全局 ATS 关闭。所有 URL（公告自定义源、AI baseURL、头像/壁纸、Yggdrasil 服务器）均允许 http 明文，中间人可嗅探/篡改：Yggdrasil 认证密码（POST body）、AI 对话全文（含 Authorization Bearer key）若走 http 即明文出网。
修改前：`<key>NSAllowsArbitraryLoads</key><true/>`
修改后：改为 NSAllowsLocalNetworking（保 Ollama 127.0.0.1 与局域网联机）+ 显式 exception domains；第三方 Yggdrasil 自定义源在 resolveAuthserverURL 中拒绝非 https（当前仅"缺协议才补 https"，显式 http:// 放行，ThirdPartyLoginViewController.m:467-471 / ThirdPartyAuthenticator.m:348-352）。

【P1】【提示词注入 → 凭据外泄链，AI 模块综合】read_file 为 AiToolPermissionReadOnly（AiFileTools.m:29-37），Safe 模式下免确认直接执行；其合法根 = POJAV_HOME（AiFileTools.m:95-116），而 POJAV_HOME=Documents（main.m:408），因此 accounts/*.json（第三方 accessToken/clientToken 明文，BaseAuthenticator.m:217）与 Documents/AI/providers.json（AI API key）都在可读范围内。外部内容（公告 JSON、Modrinth 搜索结果 description、被读入上下文的任意文件、用户粘贴文本）可注入指令诱导模型调用 read_file 读取凭据 → 工具结果进入会话历史 → 下一轮请求把全文发送到当前供应商端点（若用户配置了恶意 baseURL，即完成外传）。无命令执行工具（已核实 57 文件无 exec/system/popen/NSTask），但"读任意沙盒文件+回传 LLM"已构成敏感信息泄露面。
修改前：read_file 对任意 POJAV_HOME 内路径放行（含 accounts/、AI/）。
修改后：read_file/grep_files/list_files 维护敏感路径黑名单（accounts/、AI/providers.json、AI/sessions.json、latestlog 中 token 行），命中时返回"敏感文件，禁止读取"；或对工具结果做 token/密钥正则脱敏（eyJ…、access_token 字段）后再入上下文。

【P1】【authenticator/ThirdPartyAuthenticator.m:1383,1631-1636 + BaseAuthenticator.m:201-241】第三方 Yggdrasil accessToken/clientToken 存 authData 并随 saveChanges 明文写入 POJAV_HOME/accounts/<accountId>.json（JSON 文件无加密、无 Keychain）。同文件还持久化 availableProfiles/loginIdentifier/authserver。
修改后：第三方 token 对齐微软做法存 Keychain（Account=profileId），json 只留 username/profileId/expiresAt/accountType。

【P1】【AccountListViewController.m:782-789 与 1260-1270】ame224_applyOfflineDefaultSkin 与 ame224_updateAccountFileForLoadKey 用 NSDictionary dictionaryWithContentsOfFile:/writeToFile: 读写 JSON 账号文件——这是 plist API，无法可靠解析 NSJSONSerialization 写出的 JSON（读取常返回 nil → 功能静默失效），即便部分系统可读，writeToFile 也会把账号文件改写为 XML-plist，随后 parseJSONFromFile 解析失败、账号从列表消失（Task180 读侧过滤直接 skip）。
修改前：`NSMutableDictionary *acct = [NSMutableDictionary dictionaryWithContentsOfFile:jsonPath]; ... [acct writeToFile:jsonPath atomically:YES];`
修改后：`NSMutableDictionary *acct = parseJSONFromFile(jsonPath); ...; saveJSONToFile(acct, jsonPath);`（utils.m:670 已有现成家法）

【P1】【authenticator/MinecraftAccountJNI.m:15】`return (*env)->NewStringUTF(env, accessToken.UTF8String);` —— keychain 无令牌时 tokenDataOfProfile 返回 nil → accessToken 为 nil → NewStringUTF(NULL) 是 JNI 未定义行为（Android/iOS ART/HotSpot 通常直接 SIGSEGV）。同时 :8 `abort()` 对二次调用直接杀进程。
修改后：nil 时返回 `(*env)->NewStringUTF(env, "")` 并由 Java 侧判空走重登；abort 改为日志+返回空串。

【P1】【Natives/AI/AiAssetTools.m:1431 与 ServerService.m:227-231】下载目标 `[folder stringByAppendingPathComponent:filename]`，filename/destName 来自远端 API 响应（Modrinth file[@"filename"]、CurseForge serverPackFileName），未做路径分量清洗；恶意/被污染的镜像响应可用 "…/../../x" 逃出目标目录写入任意容器路径（SHA1 校验仅部分链路提供，写入在校验之前发生）。
修改前：`request.destinationPath = [folder stringByAppendingPathComponent:filename];`
修改后：取 lastPathComponent + 剥离 "/\\:.."（同 AvatarManager.safeFileNameForAccount 家法）后再拼接。

## 二、AI 模块专项

能力矩阵（57 文件全量核实，无 exec/system/popen/NSTask，无 shell 执行能力）：
- 读：list_files / read_file / grep_files / read_logs / read_latest_log / read_crash_report / list_instances / list_game_versions / list_settings / get_setting / match_known_errors / check_downloads / todo_list —— ReadOnly 免确认；边界 = POJAV_HOME（realpath+前缀校验，AiFileTools.resolveSafely:118-153 实现正确，symlink 归一化 + 越界拒绝）；但 accounts/、AI/ 敏感文件未拉黑（见 P1）。
- 写：write_file / edit_file（ControlledWrite，非 YOLO 需确认）/ delete_file（DangerousWrite，所有模式必确认，且仅文本扩展名白名单 :383-392，禁删目录）/ install_mod/resourcepack/shader/datapack/game_version/loader（ControlledWrite，走 PLDownloadClient+SHA1 部分）/ create_instance（ControlledWrite，含重建 POJAV_GAME_DIR 符号链接、切 profile）/ set_setting（ControlledWrite）/ todo_*（ControlledWrite）。
- 执行类能力（等价物）：set_setting 可写 java.java_args（AiSettingsTools.m:62-68）＝JVM 参数注入面（-javaagent/-Xbootclasspath 可加载沙盒内任意 jar）；YOLO 模式下零确认。
- 网络：search_*（ExternalNetwork，Modrinth→MCIM 镜像级联）/ install_* 下载（官方 CDN→cdn.mcimirror.top 兜底）。
- 无：进程执行、Keychain 访问、越出 POJAV_HOME 的文件读写、无确认的联网（ExternalNetwork 非 YOLO 均需确认）。

风险评级：中。分层设计（AiTool permission × AiSafetyManager 三档模式 × AiAgent 串行确认链）是同类启动器里少见的正规化实现；扣分项：①read_file 敏感路径无黑名单（P1）；②YOLO 模式对 ControlledWrite+ExternalNetwork 全放行且无二次警示弹窗门槛；③java_args 注入面；④SSE/工具结果无脱敏。

加固建议：敏感路径黑名单+结果脱敏；java.java_args 加入 set_setting 禁写名单（或要求 DangerousWrite）；YOLO 首次启用要求输入确认语句；providers.json 迁 Keychain（见 P0）；tool result 大小上限（防日志淹没上下文）。

SSE 流式解析（AiAPIClient.m:213-412）：健壮性良好——字节级缓冲解决多字节字符跨块截断、仅解码完整行、1MB 缓冲熔断、[DONE] 兼容、末尾无换行兜底、200ms 节流回主线程、delegate 串行队列。缺：HTTP 非 200 时仍继续收流（靠 didComplete 后统一报错，可接受）；无重试（流式请求可接受）；stop() 取消路径 onComplete 返回 error（UI 会弹"已停止生成"错误框，体验小疵）。未发现证书校验绕过（delegate 未实现 challenge 处理 = 默认系统校验）。

## 三、认证与令牌存储专项

| 令牌 | 存储位置 | 加密 | 生命周期/备注 |
|---|---|---|---|
| 微软 MSA refresh_token + MC access_token | Keychain kSecClassGenericPassword, service="AccountToken", account=xuid | 是（系统） | kSecAttrAccessibleWhenUnlockedThisDeviceOnly（MicrosoftAuthenticator.m:447）；delete+add 覆盖写；损坏条目自清（:420）；重签/换机即丢（Task185 已知并做了修复引导弹窗）；离线兜底会把 accessToken="offline" 写入（:111） |
| 第三方 Yggdrasil accessToken/clientToken | POJAV_HOME/accounts/<accountId>.json | 否（明文 JSON） | 24h expiresAt 逻辑存在但仅作展示/刷新判断；随 saveChanges 全量落盘（P1） |
| 第三方登录密码（ame131） | Keychain, service=ame131, account="authserver|login" | 是 | kSecAttrAccessibleAfterFirstUnlock（:250）；含历史服务名回退自迁移链（Task217）；删除账号时未清理该 keychain 条目（AccountListViewController ame190_deleteAccountAtIndexPath 只清微软 token）——隐私残留 P2 |
| AI 供应商 API Key | Documents/AI/providers.json | 否（明文 JSON） | 无过期（P0） |
| AI 会话/工具结果 | Documents/AI/sessions.json | 否 | 含 read_file 结果（可能含凭据），无 TTL 无清理策略 |
| ZeroTier 节点身份 | Documents/zerotier_home（libzt 自管） | 否（libzt 格式） | 非密钥类敏感数据 |
| Terraria/EasyTier | 无令牌，仅邀请码 | - | 邀请码即凭据，剪贴板自动复制（设计使然） |

其他认证发现：ASWebAuthenticationSession prefersEphemeralWebBrowserSession=YES（好）；OAuth 参数名 redirect_url（应为 redirect_uri，AccountListViewController.m:1427、MicrosoftAuthenticator.m:97）——与上游一致、依赖 login.live.com 宽容行为，P2；loadSavedName 的 accountId 直接进文件名无清洗（恶意 Yggdrasil 可控 profileId 形态 → 容器内路径污染，P2）；LocalAuthenticator profilePicURL 用第三方头像服务 api.rms.net.cn（Task220 注释称 DNS 已失效，代码 LocalAuthenticator.m:13 仍在写）P2 死链。

## 四、联机模块观察

整体质量高：PortForwarder/SOCKS5Proxy 是教科书级的 BSD socket + libzt 双栈实现（代际计数器防 accept 竞态、atomic_bool 内存序、shutdown 唤醒、SO_NOSIGPIPE/KEEPALIVE/TCP_NODELAY、30s IO 超时、stop 主线程异步等待不卡 UI）；监听一律 127.0.0.1 绑定（SOCKS5Proxy.m:459、PortForwarder.m:322）；MultiplayerManager 状态机锁纪律（_stateLock vs @synchronized 分离）与取消机制（connectionCancelled 每步检查）详尽。
问题：P2①SOCKS5 域名解析用系统 getaddrinfo（SOCKS5Proxy.m:1121-1147）——公网 DNS 解析后经 ZeroTier 连接，自带 split-DNS 陷阱（域名应解析为 ZeroTier 网内 IP 时拿到公网 IP）；P2②代理无认证，越狱设备上他进程可用作跳板进入 ZeroTier 网络（loopback 绑定缓解）；P2③TerracottaManager joinRoomWithInviteCode 预检异步块（:139-209）不响应 stopSession，取消后仍可能 setGuesting；P2④LanPortDetector 扫描 1024-65535 全端口（后台线程、loopback 瞬时 RST，性能可接受，但 progress 回调频率依赖 (scanned & 0x3FF) 设计）；P2⑤TerracottaBridge.m:46 open() 手写八进制标志位可读性差（功能正确）。

## 五、模块级架构观察与亮点

1. AI 助手模块是本 Fork 最有野心的增量：AiTool 协议 + Registry + Bootstrapper + 三档安全模式 + 确认串行链 + 会话持久化，工程化程度远超"聊天壳"水平；系统提示词（AiSettings defaultSystemPrompt:120 行）把安装纪律/版本兼容知识内嵌，配合 match_known_errors 规则表形成离线兜底。
2. 认证层 Task128/131/133/180/220 系列修复（显式 accountType、keychain 凭据免密切换、本地渲染头像、复制 bug 双保险、混合文件剥离）显示了扎实的装机取证-修复闭环文化；注释即病历，可维护性好，但也导致文件注释:代码比失衡（ThirdPartyAuthenticator 1770 行中注释约占 40%）。
3. 公告/更新链路的多级回退设计（仓库 raw → jsDelivr → 缓存 → 随包离线 JSON；BMCLAPI → 官方；Modrinth → MCIM）是可靠性亮点。
4. 重复代码：头像下载/缓存逻辑三处重复（AvatarManager.ame169、ThirdPartyAuthenticator.ame133、ServerService.iconCachePath SHA1 各一套）；UUID 补连字符逻辑在 ThirdPartyAuthenticator 内重复 4 次（:869,1400,1640,1690）；2FA/rootVC 定位逻辑在 AiSafetyManager 与 AiAskTool 重复——建议抽 utils。
5. MarkdownParser：纯手写 NSAttributedString 解析器（无 WKWebView/HTML import），从根上规避了 HTML 注入面——方向正确；缺 scheme 白名单（markdown 链接经 UITextView 默认 openURL 可触发任意自定义 scheme，对比 MinecraftNewsService.isSafeNewsLink:151-167 有白名单，标准不一）P2。

## 六、其他文件要点（P2/P3）
- BingWallpaperManager：默认开启（isEnabled 键未设即 YES，:83-89）→ 首启即向 cn.bing.com/www.bing.com 发请求，隐私上应改为默认关闭或首启征询（P2 隐私）。无遥测上传（仅 GET 拉图）。
- AnnouncementService：用户自定义公告源无 https 强制与 scheme 限制（P2，配合 ATS 关闭）；公告 JSON 的 markdown 链接/actionURL 无域名白名单（对比 MCNews 有）。
- UpdateChecker：GitHub API + 版本比较实现正确；无遥测。
- AvatarManager：safeFileNameForAccount 防穿越（好）；fetchAvatarFromURL 支持任意 URL（含内容中 file:// 的处理，NSURLSession 不支持 file 协议自然失败，无 SSRF 放大）。
- SilentAudioPlayer：0.01 音量静音保活 + mixWithOthers + 中断恢复，实现干净。
- audio_capture_bridge：环形缓冲 + 线性插值重采样（Task139 格式不匹配崩溃修复），C 层资源管理正确。
- CustomIconManager：临时图标目录 1s 后清理的时序依赖（setAlternateIconName 是系统进程异步读取，低端机可能不足 1s，P3）。
- IconLoader：NSCache+磁盘 256MB+信号量并发 15+inFlight 去重+镜像中心，完整图片库实现。
- LanPortDetector 日志正则锚定真实文案，防误匹配，质量好。

## 七、审查文件清单
全文精读（逐行）：authenticator/BaseAuthenticator|LocalAuthenticator|MicrosoftAuthenticator|ThirdPartyAuthenticator|MinecraftAccountJNI、AccountLoginViewController、AvatarManager、ThirdPartyLoginViewController（逻辑段）、AccountListViewController（逻辑段）、TerracottaManager、TerracottaBridge、terracotta.h、LanPortDetector、PortForwarder、SOCKS5Proxy、ZeroTierBridge、MultiplayerManager、MarkdownParser、UpdateChecker、AnnouncementService、AnnouncementDetailViewController、MinecraftNewsService、AnnouncementItem、BingWallpaperManager、CustomIconManager、AiFileTools、AiAPIClient、AiAgent、AiProviderStore、AiProvider、AiSettings、AiSafetyManager、AiToolRegistry、AiAskTool、AiSettingsTools（核心段）、AiLogReader（核心段）、AiInstanceCreator、AiDownloadProbe、AiToolBootstrapper、AiTodoTool（核心段）、AiCrashAnalyzer（核心段）、AiInstanceCreator、AIViewController（发送/停止/流式段）、AIProviderConfigViewController（key 字段段）、ServerService（核心段）、SilentAudioPlayer（核心段）、audio_capture_bridge（核心段）、IconLoader（头部+架构注释）。
抽查/危险模式扫描：MultiplayerViewController、TerracottaViewController、BackgroundManager、BackgroundSettingsViewController、HomeCustomizeViewController、ImageCropperViewController、BingWallpaperGalleryViewController、ServerListViewController、ServerDetailViewController、ServerItem、MinecraftNewsViewController、AnnouncementListViewController、AIInputBarView、AIMessageCell、AISessionListViewController、AISystemPromptEditorViewController、AiSession、AiMessage、AiSleepTool、AiInstancesTool（缓存/清单段）、AiAssetTools（安装/下载/镜像段）、Info.plist、utils.m(JSON helpers)、main.m(POJAV_HOME)。
结论：审查范围内未发现命令执行类 AI 工具、未发现证书校验禁用代码、未发现崩溃上报/遥测外发；最高风险集中在「明文凭据存储（AI key + 第三方 token）+ ATS 全局关闭 + AI read_file 敏感文件可读」三件事的组合上。

Task 2-d 完毕。

---
Task ID: 2-f
Agent: Explore(工程化构建)
Task: 审查 Prisma 工程化与构建体系（Makefile / CI / pbxproj / entitlements / 仓库卫生 / 发布工程）

Work Log:
- 通读 Makefile 全文 936 行、.github/workflows/development.yml 412 行、JavaApp/Makefile 205 行、project.pbxproj 163 行、3 个 entitlements 全文、.gitignore/.gitmodules/crowdin.yml/AGENTS.md/docs/surveys
- 量化仓库体积：.git pack 128.1MiB、工作区约 620MB（Natives 432MB）；git ls-files 13313 个文件、HEAD 跟踪内容约 452MB，逐目录 du + git blob top30 定位大头
- git 历史仅 50 commit（根 commit 为 "Add files via upload"，非上游共享历史），其中 24 条为 "Delete latestlog.txt" 式补救；无任何 tag
- 实锤 CI 问题：workflow 未设 RELEASE=1 → 发行 IPA 主程序 native 以 Debug(-O0) 编译；未设 RUNNER=1 且无 depends/ 缓存 → 每次下载 4 套 JRE；VirGL 三件套未 commit-back → Mesa 链每次全量重编
- 实锤 Makefile 缺陷：`all: clean ...` 竞态；make package 覆写并删除被跟踪的 entitlements.codesign.xml；`$(ls ...)` 被 make 展开为空（两处）；.PHONY 不全；三处重复 glslang 库解析块
- scripts/ 分类：248 文件中 229 个为一次性任务脚本（verify_task124/task97/test8），仅 4-6 个被构建引用

Stage Summary:
- 完成 2-f 审查报告（问题清单 18 条：P0×2 / P1×9 / P2×7 + 体积大头测量 + Makefile/CI 结构分析 + 卫生整改三类清单 + 亮点），全文见下；核心结论：构建能跑通且 CI 修复方法论成熟，但发行产物以 -O0 编译、发布链路断流（main 分支永不发布 nightly）、约 250MB 预编译二进制撑爆仓库，是三处最值得立即处理的工程债

=== 审查报告全文 ===

# 2-f 工程化与构建体系审查报告

## 一、问题清单

【P0-1】Makefile:237 `all: clean native java jre assets payload package dsym`
- 位置：Makefile 目标 all；AGENTS.md「构建命令 make all」
- 问题：clean 是 all 的前置目标。并行 `make -j all` 时 clean（rm -rf Natives/build JavaApp/build artifacts）与 native/java 竞态，直接构建失败或产物损坏；串行时每次必全量重建，增量编译永久失效。此外 payload 已依赖 native/java/jre/assets/全部 dep_*，all 再列一遍属冗余。
- 建议：`all: payload package dsym`（去掉 clean），另设 `rebuild: clean all`；或在 all 上加 .NOTPARALLEL。

【P0-2】CI 发行产物以 Debug(-O0) 编译主程序
- 位置：development.yml 构建步骤（未传 RELEASE）；Makefile:18 RELEASE?=0 → CMAKE_BUILD_TYPE=Debug → Makefile:268 native 的 cmake
- 问题：dep_mg/dep_nggl4es/dep_gl4eszl2 都钉死 RelWithDebInfo（Task27 专门修过 -O0 assert 全激活的崩溃），但主构建（Natives/CMakeLists.txt 无优化兜底）在 CI 里默认 Debug：发行 IPA 的启动器 ObjC/C 代码全部 -O0。配置割裂 + 发行性能损失。
- 建议：CI 构建 `RELEASE=1`（CMake Release 仍保留 -g 可出 dSYM），或在 Natives/CMakeLists.txt 里强制默认 RelWithDebInfo。

【P1-1】entitlements.codesign.xml 三重身份冲突 + 泄露真实 TeamID
- 位置：entitlements.codesign.xml；.gitignore:17；Makefile:903-906（package）
- 问题：①文件被 git 跟踪，却在 .gitignore 里；②`make package`（有 TEAMID 时）printf 覆写该文件、codesign 后 `rm -rf entitlements.codesign.xml`——构建直接删掉被跟踪的源文件；③内容混入两个 Team：application-identifier 用 95J8WZ4TN8（真实个人团队，入仓），keychain-access-groups 却是 FBT742498U.*（PojavLauncher 上游残留）。
- 建议：静态三件套与"生成式 entitlements"二选一——把动态生成路径改写到 $(OUTPUTDIR)/entitlements-gen.plist 并传给 METHOD_CODESIGN；从 ignore 列表移除；仓库内文件用占位 TeamID（如 TEAM.placeholder）。

【P1-2】project.pbxproj 泄露个人签名信息
- 位置：Amethyst.xcodeproj/project.pbxproj:97-100/110-113
- 问题：SIGNING_TEAMID=TF9842L8S8、TEAMID=95J8WZ4TN8、PROVISIONING=/Users/evaluna/...（真实用户名+真实团队 ID 入仓）。
- 建议：改为 ?= 可覆盖的默认占位值（Makefile 已是 -1 默认，pbxproj 反而写死真值）；历史泄露可评估是否需处理。

【P1-3】仓库体积根因（git clone 大头实测）
- 测量：.git pack 128.1MiB；工作区约 620MB；跟踪内容 452MB（13313 文件）。大头：
  - Natives/resources/Frameworks/ 140.1MB：24 个预编译 dylib/framework，其中 libMobileGL.dylib 83.7MB（历史 blob 81.8MB，单项最大）
  - Natives/external/ 182.8MB：MobileGlues 108.7MB（源码+libraries/ios 预编译 .a 26MB）；LTW 47.6MB（含 mesa 生成物 nir_opt_algebraic.c 19.7MB、已编译二进制 glsl_compiler 10.9MB 入库）
  - Natives/terracotta/ 54.7MB：libterracotta.xcframework（sim-fat.a 36.1MB + ios .a 18.6MB，双架构预编译静态库）
  - JavaApp/libs/ 34.2MB：48 个 jar、3 套 LWJGL 并存（lwjgl 9.5MB / lwjgl-333 8.8MB / lwjgl-341 13MB；lwjgl-vulkan.jar 三份共 20.4MB）
  - ThirdParty/ 10.3MB（构建引用，可接受）；根 lwjgl.jar 9.7MB（LWJGL 补丁基座，构建输入）
  - scripts/ 2.7MB；worklog 两件 0.7MB
- 问题：约 250MB 预编译二进制直入 git；且 workflow「Commit MobileGL dylibs back to repo」步骤（vars.COMMIT_MOBILEGL=1 时）会每次 CI 把新 dylib commit 回 main，历史无上限增长（已为此放大 http.postBuffer 到 500MB）。
- 建议：二进制迁 Git LFS 或「Release 附件 + 构建期下载（带 sha256）」；terracotta 只留实际链接的架构切片；LTW 清理生成物与 glsl_compiler；commit-back 机制改为 artifact 传递而非入库。

【P1-4】下载零校验、依赖未锁定（供应链）
- 位置：Makefile:158-173（4 套 JRE 自 assets.angelauramc.dev）、741-753（Mesa 25.0.7 自 archive.mesa3d.org，VIRGL_MESA_VERSION ?= 可覆盖）、workflow:151（ccache tarball 自 GitHub release）
- 问题：全部无 sha256 校验；brew 依赖（meson/ninja/bison/pkg-config）无版本 pin；actions/checkout@v4 等按 tag 引用未按 SHA 固定。子模块侧做得好（glslang f5f664d 等 6 个 gitlink 锁 commit + Makefile 强制校验）。
- 建议：为 6 个下载源加 sha256 环境变量+校验；mesa 版本改"唯一真值+patch 兼容断言"已有；actions 升级到 SHA pin。

【P1-5】版本管理与发布链路断裂
- 问题：三张版本皮——Makefile VERSION:=1.0（ipa 文件名 com.air-devs.air-1.0-*.ipa）、Info.plist CFBundleShortVersionString=6.5.0、无 tag/CHANGELOG；nightly release 仅在 `github.ref == refs/heads/feat/sdl3` 时发布（development.yml:378），而默认分支是 main → push main 永不发布；release 采用"删 nightly-sdl3 再建"策略，无版本历史可回溯；README 却挂 release 下载 badge。
- 建议：单一版本源（如 VERSION 文件，Makefile 与 Info.plist 构建期注入）；发布条件改 main 分支（或显式说明 feat/sdl3 为发布分支）；从 worklog 生成 CHANGELOG.md；引入 semver tag。

【P1-6】JRE 下载逻辑 bug + CI 每次全量下载
- 位置：Makefile:160、299
- 问题：`[ ! -f "$(ls jre$(1)-*.tar.xz)" ]` 中 `$(ls ...)` 是 make 变量引用而非 shell——恒展开为空：①"已有 tarball 就跳过下载"分支永不生效；②行 299 的 tarball 清理永不执行（depends/ 里 tar.xz 越积越多）。同时 CI 未设 RUNNER=1 也未缓存 depends/ → 每次 CI 下载 JRE 8/17/21/25 四套。
- 建议：改 `$$(ls ...)`；CI 缓存 depends/（key 绑 JRE URL 哈希）或设 RUNNER=1+预置。

【P1-7】VirGL 快路径失效 → 每次 CI 全量重编 Mesa
- 位置：Makefile:668-676（Frameworks 有 libOSMesaVirgl/libvtestserver/libepoxy.dylib 即跳过）；实测 Frameworks/ 24 项中三者皆无
- 问题：Task215/216 设计的"commit-back 后跳过整链"从未兑现 → 每次 CI 跑 meson 全链（epoxy+virglrenderer+Mesa 25.0.7），是健康构建 8-13 分钟里的最大不确定项；且 dep_virgl 失败放行（fail-open）导致产物内容随构建机状态漂移。
- 建议：像 MobileGL 一样 commit-back 三件套（或 cache Natives/build/virgl-*，key=VIRGL_MESA_VERSION+patch 哈希）；fail-open 同时打印醒目 artifact 摘要。

【P1-8】.gitignore 缺口 → 24/50 提交是"Delete latestlog.txt"式补救
- 实证：历史曾入库 latestlog(1).txt、latestlog.old.txt.txt、fatal_trace 2.txt、hs_err_pid1381.log、IMG_9288.jpeg 等；当前 ignore 只有 ci_task83b_*.log 一条日志规则；另有已跟踪却被 ignore 的 /docs 与 entitlements.codesign.xml（新文档/新 entitlements 默认不进 git，坑新人）、垃圾条目 $null。
- 建议：追加 latestlog*、hs_err_*、fatal_trace*、*.log、build_output.log、mobilegl-build.log、javaver.txt、IMG_*.{png,jpeg}、.DS_Store（已有）；删除 /docs、entitlements.codesign.xml、$null 三条。

【P1-9】死路径与文档腐化
- 位置：Makefile:836-847（payload 找 $(SOURCEDIR)/TouchController/libproxy_server_ios*.a——根目录无 TouchController/，该分支恒走 skip）；AGENTS.md（宣称 macOS 14 / Xcode 15.4/16 / SDK 17.5，实际 macos-15 / Xcode 26；引用不存在的 .github/workflows/vendor-mobilegl.yml 与 TouchController/ 根目录）。
- 建议：删除 TouchController 死分支或恢复该目录；AGENTS.md 环境一节随 workflow 同步（或改为读 CI 配置的脚本生成）。

【P2-1】scripts/ 229/248 为一次性任务脚本（2.7MB）入库——见卫生清单
【P2-2】worklog.md(380KB)+worklog-archive.md(352KB) 入库并随任务无限增长（当前版本管理下尚可接受，但建议归档机制）
【P2-3】.PHONY 不全：缺 payload/dep_mg/dep_shader_shims/dep_openal_shim/dep_mithril_glshim/dep_nggl4es/dep_gl4eszl2/dep_virgl_build/dep_angle_freeze/dep_sdl3_guard——目录中恰好出现同名文件时目标被遮蔽；check 目标在仓库根写临时 javaver.txt
【P2-4】JavaApp/Makefile 逐文件 javac（76 次 fork），曾有 cp/javac 并行竞态史（空 class 重试补丁）——改单次 javac 全量编译可同时消灭竞态与时长
【P2-5】四代命名同仓：Prisma（仓）/Amethyst（xcodeproj）/AngelAuraAmethyst（app+target）/PojavLauncher（productName）/com.air-devs.air（bundle id）；新人地图缺失，建议集中一处"命名对照表"
【P2-6】sideload.xml/trollstore.xml 缺 <?xml?> 声明；Makefile 内嵌 printf 生成 codesign entitlements 的 plist 模板（行 904）与静态文件重复维护
【P2-7】xcodeproj buildToolPath=/usr/local/bin/gmake 硬编码（Apple Silicon brew 实际在 /opt/homebrew/bin/gmake）；matrix 里 tvos/visionOS 平台从未在 CI 构建（Makefile 支持但无验证）

## 二、Makefile 结构分析

目标清单（26 个）：all / help / check / clean / native / java / jre / assets / payload / package / dsym / codesign / deploy / dep_mg / dep_mobilegl(空占位) / dep_openal_shim / dep_mithril_glshim / dep_shader_shims / dep_nggl4es / dep_gl4eszl2 / dep_virgl / dep_virgl_build / dep_angle_freeze / dep_sdl3_guard。
依赖图：all→(clean,native,java,jre,assets,payload,package,dsym)；payload→{native,dep_mg,java,jre,assets,dep_shader_shims(dep_mg),dep_openal_shim,dep_mithril_glshim,dep_nggl4es(dep_mg),dep_gl4eszl2,dep_virgl,dep_angle_freeze,dep_sdl3_guard}；package/dsym→payload。jre→native（仅为拷 libawt_xawt，拖慢下载并行性）。
最长/最复杂目标：dep_virgl_build（100 行，含 meson cross/native file 生成、三段构建、Mesa 下载+补丁）、dep_mg（88 行，子模块断言+双幂等 patch+超构建布局兜底查找）、dep_shader_shims（64 行）、payload（69 行）。METHOD_* 7 个 define。
重复代码：glslang 静态库解析块（主路径+find 兜底+断言）在 dep_mg/dep_shader_shims/dep_nggl4es 出现 3 份（各约 30 行）；CMake 交叉配置 5 份（native/dep_mg/dep_nggl4es/dep_gl4eszl2/...）；xcrun clang -dynamiclib shim 链 3 份。
重构建议：①拆 deps.mk/mono 两个 include；②把 glslang 解析与交叉配置收敛为 define（一次修改全局生效，Task45/46 的"布局漂移"类事故可免疫）；③all 去 clean；④.PHONY 补全；⑤METHOD_DOWNLOAD（wget+sha256+重试）统一函数；⑥`$(ls ...)`→`$$(ls ...)`；⑦ccache 用 -DCMAKE_C(XX)_COMPILER_LAUNCHER=ccache 接管 CMake 侧（当前靠 CC 环境变量，直接 xcrun clang 的 4 个 shim 编译与 meson 链均未覆盖）；⑧VERSION 单一来源。
健壮性：TAB/空格无混用（grep 无空格缩进 recipe）；.SHELLFLAGS=-ec + || exit 1 模式成熟；bashism（==）在 SHELL:=/bin/bash 下安全但不可移植；SOURCEDIR 用 printf %q 引号技巧对含空格路径勉强可用。

## 三、CI 配置分析

流程：push/PR/dispatch → concurrency 组取消旧构建 → 选 Xcode≥26（GITHUB_ENV 固化 SDKPATH/DEVELOPER_DIR）→ 恢复 ccache(2G)/brew/ccache-tool 三缓存 → brew 装 gmake/temurin8/ldid/meson/ninja/bison/pkg-config（|| true 吞错）→ 清场 → checkout@v4（shallow）→ gitlink 清理守卫 → submodule --init --recursive（GIT_LFS_SKIP_SMUDGE=1）→ 构建（CC/CXX=ccache clang；gmake dsym package；第二遍 TROLLSTORE_JIT_ENT=1 出 tipa）→ 失败注解 → 4 个 artifact（ipa/tipa/dSYM/MobileGL dylib+log）→（可选）commit-back →（仅 feat/sdl3 push）删+建 nightly-sdl3 release。
瓶颈排序：①Mesa/VirGL 全链重编（快路径失效，见 P1-7）；②4 套 JRE 下载（无缓存无校验，P1-6）；③MobileGlues 编译（ccache 已缓解，实测 3.4 分钟）；④brew 安装（缓存已缓解）；⑤第二遍 gmake 重复 zip 打包。
缓存命中率提升具体措施：a) cache depends/（key=四个 JRE URL 哈希，restore-keys 前缀）——每次省数百 MB 下载与 1-3 分钟；b) VirGL 三件套 commit-back 或 cache $(WORKINGDIR)/virgl-*（key=VIRGL_MESA_VERSION+patches 哈希）——预计省 5-15 分钟；c) ccache max_size 2G→4G（10GB 配额余量大），MobileGlues/vgpu/NG-GL4ES 全覆盖；d) ccache key 纳入 Natives/external/MobileGlues/** 哈希让内容漂移精确换桶；e) Java 单次 javac。
安全评价：✅无 pull_request_target、fork PR 无 secrets、timeout 60min、concurrency 取消、错误注解匿名可读；⚠️CURSEFORGE key 编译进公开 IPA（上游模式，需知悉）；⚠️actions 按 tag 未按 SHA；⚠️ccache tarball 无校验；⚠️job 级 contents:write 偏宽（可拆 build/publish 双 job，publish 仅 main）；⚠️brew install 全部 || true（真失败会被延后到 make 深处才爆）。

## 四、仓库卫生整改清单

保留（有长期价值）：Makefile 引用的 4 个补丁脚本（patch_angle_surface_freeze / patch_jre_upcall_mirror / patch_sdl3_eventfilter_guard / patch_shaderc_lvalue_guard——最后一个注释声明"留仓考古"）；build_lwjgl.sh、resign_adhoc.sh、disas_getimage.py、disasm_gl1.py、patch_gl4es_ggstr_nullguard.py、patch_gl4es_rtld_default.py、patch_lwjgl_delegate_dlsym.py（退役渲染器补丁，建议集中到 scripts/retired/ 并在 README 标注状态）；根 announcements.json/help-faq.json（App 运行时经 raw.githubusercontent/jsdelivr 拉取的公告与 FAQ 源——属有意设计，保留但注意"仓库接管=内容注入"风险）；worklog.md；docs/surveys 两篇上游调查；patches/ 两个 patch（构建引用）；crowdin.yml；ThirdParty/（构建引用）。
归档（移出主分支，保留可考）：worklog-archive.md → docs/history/ 或 archive 分支；scripts/ 中 229 个一次性任务脚本（verify_taskNNN.py 124、taskNNN_* 97、test_task* 8）→ 独立 task-artifacts 仓库或 archive 分支（保留最近 1-2 轮的验证脚本在主分支作 CI 自检样例）；poll_ci_task{182,206,209,210,213,223}.sh、fix_task47_makefile.py、fake_impl44.c。
删除：根目录 latestlog*/hs_err*/fatal_trace*/IMG_*（已在 HEAD 外，仅需 ignore 防复发）；.gitignore 的 $null 条目；LTW 生成物 nir_opt_algebraic.c 与编译二进制 glsl_compiler（构建可再生）；terracotta 未用架构切片；三套 LWJGL 中运行时未用的冗余 jar（libs/lwjgl 的 vulkan 等仅编译期 classpath，可精简）；JavaApp/libs 与根 lwjgl.jar 建议迁 LFS 而非删除。

## 五、设计亮点

1. AI 任务制工程闭环：worklog 根因链 + verify_taskNNN 验收脚本 + commit message 内嵌 CI run id 修复谱系（Task223 四轮修复每轮都先审计"未编译到的 TU 集"）——错误分类账方法论罕见地严谨。
2. 二进制手术幂等化：三个 patch_*.py 全部"幂等 + 字节指纹不匹配即响亮失败"，把 dylib 版本漂移变成构建期错误而非装机期玄学。
3. dep_virgl fail-open 优雅降级：可选渲染器构建失败只隐藏 UI 入口不拖垮主构建（Task216 hotfix 3 兑现设计注释）。
4. ccache 绕开 brew 依赖树：官方预编译 darwin 包 ~2MB 直装（附 run 36722042665 的 brew LLVM 源码编译事故复盘），brew 只装 make/temurin/ldid/meson。
5. glslang 供应链：子模块钉 commit + apply --check 幂等补丁 + 三重存在性断言 + 超构建/独立布局双路径兜底（Task45/46 教训直接固化进 Makefile）。
6. LWJGL 分层 jar 装配与 Forge 模块层 split-package 考古（JavaApp/Makefile 内注释即设计文档）。
7. entitlements 差异有据：sideload 主动摘除内存 entitlements 防假"Enabled"指示（Task91 注释），trollstore 才保留全家桶。
8. CI 细节：concurrency cancel-in-progress 缓解 runner 排队；错误注解匿名可读（无登录也能看失败行）。

## 六、审查覆盖清单

✅ Makefile 936 行全文（26 目标、7 define、TAB 健壮性、.PHONY、缓存、下载校验、竞态）
✅ development.yml 412 行全文（触发/矩阵/缓存/产物/发布/安全/并发/超时）
✅ JavaApp/Makefile 205 行全文（javac 模式、jar 分层、竞态补丁史）
✅ project.pbxproj 163 行全文（PBXLegacyTarget、个人签名信息、gmake 路径）
✅ entitlements×3 全文比对（TeamID 一致性、XML 声明、设计意图）
✅ .gitignore/.gitmodules（6 子模块钉 commit）/crowdin.yml
✅ AGENTS.md/README/README_EN(标题核对)/docs/surveys 抽样
✅ 仓库体积测量（du 逐层 + git blob top30 + 逐目录 tracked 聚合）
✅ git 历史（50 commit 全量统计、根 commit、"Delete"提交模式、无 tag）
✅ scripts/ 248 文件分类与构建引用 grep
✅ JavaApp/libs 48 jar 清点、Frameworks 24 dylib 清点、VirGL 快路径产物核实
✅ Natives/CMakeLists.txt 优化配置核查（无兜底）
未覆盖（移交后续任务）：CMakeLists 全文构建选项细节、TouchController/Natives 内部实现、.github/ISSUE_TEMPLATE 内容、GitHub Releases 线上状态（需网络）。

---
Task ID: 2-c
Agent: Explore(下载与内容服务)
Scope: Natives/ 下载与内容服务层 51 个文件（约 3.36 万行）逐文件审查：网络健壮性 / 文件操作安全 / 并发 / API Key / 内存 / 数据一致性 / 重复代码

## 一、总体结论

下载体系实际存在 **5 套并行下载栈**：① PLDownloadClient（统一下载器，质量最高）② MinecraftResourceDownloadTask（AFNetworking，原版/整合包游戏文件）③ WorldService 自建 NSURLSession delegate ④ DownloadViewController 内散落的 sharedSession 任务 ⑤ ModUpdateService 走 API 层同步请求。统一化（spec Task 4.2/5.x）覆盖了 Mod/Shader/ResourcePack/DataPack 四个 Service，但 World、DownloadViewController 部分路径、ForgeInstallViewController（自建 AFURLSessionManager）仍是旧栈。核心文件 PLDownloadClient/DownloadTaskManager 工程质量显著高于外围（大量"病历式"修复注释、终态保护、负 delta 回退等），但**文件安全（Zip Slip）只在 DataTransferService 修了，ModpackImport/World/ModpackUtils 全部裸奔**，这是本轮最重要发现。

## 二、逐文件问题清单（P0/P1 附代码）

### P0-1【ModpackUtils.m:8-33 + ModpackImportService.m:1230-1244/1656/1582 + WorldService.m:320】Zip Slip / 任意路径写入
`ModpackUtils archive:extractDirectory:toPath:` 直接拼接 zip 条目名：
```objc
// 修改前（ModpackUtils.m:14-15）
NSString *fileName = [fileInfo.filename substringFromIndex:dir.length+1];
NSString *destItemPath = [path stringByAppendingPathComponent:fileName]; // "overrides/../../x" 越界
```
三处入口均无 "../"、绝对路径、反斜杠净化：① Modrinth/CurseForge overrides 解压；② PlainZIP/MMC 整包解压（extractOverrides plainzip 分支）；③ 下载文件落盘 `destPath = [destDir stringByAppendingPathComponent:relativeUnder]`（.mrpack 的 files[].path 与 CF fileName 来自不可信 manifest/HEAD 头）。恶意整包可在沙箱内覆盖 profiles.json、versions/*.json（JVM 会执行的 jar/json）→ 持久化破坏。同库 DataTransferService.m:402-406 已有正确实现可抄：
```objc
// 修改后（对齐 DataTransferService 的净化 + 逐段重组）
if (p.length == 0 || [p hasPrefix:@"/"] || [p containsString:@"../"] || [p isEqualToString:@".."]) { 拒绝; }
NSString *destItemPath = [path stringByAppendingPathComponent:fileName];
if (![destItemPath hasPrefix:[path stringByAppendingString:@"/"]]) { 拒绝; } // 规范化后前缀校验
```
另注：仓库只 vendored UnzipKit 头文件（Natives/external/UnzipKit/ 仅 .h），链接的 UnzipKit framework 版本是否含上游 Zip Slip 修复无法在仓内验证，必须按"库不设防"做纵深防御。

### P0-2【CurseForgeMurmurHash.m:71-89】整文件读内存 ×2，大 mod 直接 OOM 被杀
```objc
// 修改前
NSData *data = [NSData dataWithContentsOfFile:path];      // 全量 jar 入内存
uint8_t *filtered = malloc(length);                        // 再复制一份等长缓冲 → 峰值 2×文件大小
```
Mod 更新反查对每个 mod 计算指纹，大型整合包单 jar 200-400MB 时瞬时 400-800MB 峰值，iOS jetsam 直接杀进程（用户表现：更新检查闪退）。ModUpdateService.checkUpdateForMod 对列表内每个 mod 都触发，批量检查时风险放大。修改后：流式过滤（滑动窗口跨块处理 4 字节对齐 + 尾部 carry），或至少 `mmap`（dataWithContentsOfFileMapped）+ 单份过滤缓冲。同模式问题：ModService.m:164-174 sha1ForFileAtPath、MinecraftResourceDownloadTask.m:1134 checkSHAIgnorePref（且 AFNetworking completion 默认主线程回调 → 大文件 SHA1 阻塞主线程）。PLDownloadClient.m:64-91 的 PLDownloadSHA1HexForFile 已是正确流式实现，应收敛复用。

### P1-1【MinecraftResourceDownloadTask.m:69】请求超时 86400s
```objc
// 修改前
configuration.timeoutIntervalForRequest = 86400;   // 24 小时"无数据超时"，等于没有超时
// 修改后
configuration.timeoutIntervalForRequest = 60;      // 对齐 PLDownloadClient.m:372 的 60s；资源总超时单独设
```
卡死连接占满 HTTPMaximumConnectionsPerHost=24 的连接池，数百 asset 下载被少数僵尸连接拖死。

### P1-2【ResourcePackService.m:134-197 / DataPackService.m:156-243 / WorldService.m:73-176】相对 gameDir 未解析（Task219/225 只修了 Mod/Shader）
ModpackImportService 给每个导入整包写 `gameDir = "./custom_gamedir/<id>"`；ModService.resolveAbsoluteGameDirForProfile 对 "./" 前缀做了相对 POJAV_GAME_DIR 解析，但 ResourcePack/DataPack/World 三家直接 `prof[@"gameDir"] stringByAppendingPathComponent:@"resourcepacks/saves/datapacks"`——相对路径按进程 CWD 解析（fileExistsAtPath 语义，ModService 注释里自己写过这个坑）。后果：在导入的隔离整包上下载资源包/世界/数据包，要么找不到目录回退共享根（游戏内不可见），要么写到 CWD 相对路径的错误位置。修法：把 ModService 的 resolveAbsoluteGameDirForProfile + ame225 嗅探抽成公共工具（PLGameDirResolver），四家统一调用。

### P1-3【DownloadViewController.m:4724-4755 downloadModVersion:modInfo:completion:】绕过统一下载器
```objc
// 修改前：sharedSession 直下，无 SHA1 / 无镜像 / 无任务注册 / 无 HTTP 状态检查
NSURLSessionDownloadTask *downloadTask = [[NSURLSession sharedSession] downloadTaskWithURL:url ...
// 修改后：构造 PLDownloadRequest（expectedSHA1 = version.primaryFile.hashes.sha1，
//         candidateURLs = PLMirrorCenter，registerTaskWithResourceType:Mod）走 [PLDownloadClient sharedClient]
```
错误页 HTML 会被当作 .jar 落盘（didFinish 不看 statusCode），且大文件无任何进度反馈。调用点 3704（Fabric API 安装）。

### P1-4【WorldService.m:52-58, 382, 596-692】自建下载栈缺完整性三件套
timeoutIntervalForResource=600s（大世界慢网必超时）；无 HTTP 状态检查（HTML 存成 zip 后解压报迷惑错误）；无 SHA1（Modrinth 版本接口本身提供 sha1，未利用）。另外 extractWorldZipAt 解压失败时仅清理"空目录"，半成品世界目录残留会出现在存档列表（level.dat 校验只打日志）。建议整体迁 PLDownloadClient + 解压到临时目录成功后 rename。

### P1-5【MinecraftResourceDownloadTask.m:223-224 等多处】completionHandler 强引用 self
```objc
// 修改前（与 weakSelf 混用）
} completionHandler:^(NSURLResponse *response, NSURL *filePath, NSError *error) {
    if (self.progress.cancelled) {   // 强捕获 self，AF 会话任务持有 block 直至任务结束
// 修改后：统一 weakSelf→strongSelf 模式（同文件 620-655 行已是正确写法）
```
配合 P1-1 的 86400s 超时，僵死任务会把整个 MinecraftResourceDownloadTask 实例（含数百 asset 的 fileList/progressList）拖在内存里。

### P1-6【PLPreferences.m:501-511 + installer/modpack/CurseForgeAPI.m:187-225】CurseForge API Key 明文存 NSUserDefaults + 日志泄漏前缀
Key 存 `PREF_CURSEFORGE_API_KEY`（未加密 plist，iCloud 备份/文件 App 可读）；apiKey getter 每次请求 NSLog 前 8 字符（latestlog 用户可导出共享）。三层 fallback（运行时偏好 > 编译期宏 > Info.plist）中宏/Info.plist 等于把（可选的）key 烧进二进制。建议：运行时 key 迁 Keychain（项目已有 keychain service 先例，见 worklog Task216/222），删 NSLog 或只打长度。UI 输入侧（secureTextEntry、占位垃圾键清洗）做得不错。

### P2 问题（按文件，均给出修改建议）
- DownloadTaskManager.m:1203-1233 handleResumeData: 在锁外写 item.supportsResume/resumeDataPath（与其他字段 NSLock 保护不一致，建议挪锁内）；retryTaskWithId:707-732 retryHandler 返回 nil 时任务停在 Pending 无兜底（建议置 Failed）。
- PLDownloadClient.m:756-797 didFinishDownloadingToURL 在 delegate 队列读 op.urlIndex/op.request（stateQueue 写，技术性 data race；建议把状态检查并入 pendingDownloadError 构造后移 stateQueue）；resumeData 换候选 URL 时仍续传原 URL（544-560，建议候选切换时丢弃 resumeData）。
- MinecraftResourceDownloadTask.m:239/276 重试固定 0.5/0.3s 无退避（数百文件同时风暴；改对齐 1/2/4s）；556-562 substringToIndex:2 无长度防御（hash 异常即 NSRangeException）；676-678 title 为空时包路径 `/.zip`；parseModpack 前的临时 zip 在 parse 失败路径不清理（695-705）。
- ModService.m:655-711 downloadMod 的 destinationPath 用 mod.fileName，为空时落 `mods/` 目录（ShaderService 已有 fileName 兜底 + 强制 .zip 后缀，Mod 没有——又是复制分叉的例子）。
- ModpackImportService.m:2687-2693 saveImportedModpack 把整个 modpackInfo（含 indexData/manifestData/iconBase64）存 NSUserDefaults，大 manifest 拖慢启动读写；2697-2742 deleteModpack 直接 rm 整包目录，无 Task224 式 saves 备份（重导入有备份、删除没有，语义不对称）；2439-2461 轮询忙等 30min（改 dispatch_group/KVO 回调）；1506 `if (self.cancelled)` 裸读 ivar（其他处都 @synchronized）。
- ModsManagerViewController.m:1248-1267 更新替换"先删旧再移新"，move 失败旧文件已丢（建议 backupItemName 或先 rename 旧文件为 .old）。
- DownloadHistoryStore.m:45-76 ensureLoaded 的 loaded 标志先置位后加载，并发首次访问可能读到空表（建议 dispatch_once 或加载完成后再置位）；DownloadTaskItem.m:163-175 historyDictionary 恒 "success"，失败从未入历史（功能缺口）。
- MinecraftResourceUtils.m:41/45/151/260 libName 无 ":"、componentsSeparatedByString:[2]、remoteVersionList[index+1] 三处越界崩溃点（数据异常即崩，加防御）。
- ModpackImportService.m:2017-2083 每文件新建临时 NSURLSession（有 finishTasksAndInvalidate，无泄漏，但 10s 同步等待占用并发槽；BMCLAPI 故障时每文件最坏 25s（元数据 10s + HEAD 15s），建议会话复用 + 结果缓存）。
- installer/ForgeInstallViewController.m:1208 每次下载 new AFURLSessionManager（旧实例 dealloc invalidate 可解，但建议复用）；下载无 SHA1/镜像候选。
- 死代码：Natives/CurseForgeAPIKeyViewController.m 不在 CMake 目标（CMakeLists.txt:636 只编 installer/ 版），两份已发生行为漂移（Natives 版还 import BackgroundManager），建议删除 Natives 版。

## 三、Service 间重复代码模式（可抽象性评估）
1. **PLDownloadClient 封装层 4 份拷贝**：ModService.m:713-895 ≈ ShaderService.m:408-588（diff 仅 10 行）≈ ResourcePackService.m:447-630（diff 44 行）≈ DataPackService.m:497-680（diff 44 行）。startPLDownloadWithRequest / handlePLDownloadDelta / handlePLDownloadSpeed / handlePLDownloadCompletion / restartPLDownloadForTaskId / cleanupPLDownloadStateForTaskId + downloadXXX 的三连 overload + 七个跟踪字典 + 初始化 10 行，逐字雷同，仅 resourceType 常量/错误域名/handler typedef 不同。→ 建议 `PLResourceDownloadService` 基类（模板方法：destinationFolderForProfile:、resourceType、errorDomain），四个 Service 收缩为 30 行配置子类。这一处重构可消掉约 550 行重复代码，且能一次性修复"分叉漂移"类 bug（如 P1-2、ModService 无 .zip 兜底而 Shader 有）。
2. **目录解析 5 份拷贝**：existing/ensureXxxFolderForProfile 在 Mod/Shader/ResourcePack/DataPack/World 各写一遍，行为已经分叉（见 P1-2）——重复导致语义漂移的实证。
3. **版本选择页**：ModVersionViewController(823 行) vs ShaderVersionViewController(828 行) diff 仅 193 行（~88% 相同）；DownloadViewController 内 mod/shader/resourcepack/datapack/modpack 五套"搜索→详情→版本→下载"流程靠复制 + pendingDownloadType 魔法串分发。
4. **下载栈 5 套**（见总体结论）：MinecraftResourceDownloadTask 的"候选轮换重试"与 PLDownloadClient 的 candidateURLs + retry 机制重复实现且行为不一致（退避、SHA 时机、进度语义）。

## 四、模块级架构观察
- DownloadTaskManager 是质量很高的状态机：终态拒绝回跳、取消抑制、槽位信号量与 slotOwningTaskIds 严格配对、快照 debounce+节流双通道、UI 通知 0.2s 节流、恢复时 resumeData 存在性校验——设计意图清晰、注释带完整病历。风险集中在 rawTask 多态协议（NSURLSessionTask suspend 计数 / PLDownloadOperation pause / id best-effort）的 holdCounts 平衡上，新增 rawTask 类型容易踩坑，建议文档化或改协议接口。
- 进度上报存在三种范式并存：NSProgress 树（MCDL）、delta+generation（PL 封装层）、snapshot 字典（WorldService），下载中心 UI 被迫全兼容。
- PLDownloadClient 的 .part + SHA1/EOCD + replaceItemAtURL 原子落盘是全仓数据一致性的黄金标准，但只有 4 个 Service 享受；World/Forge installer/MC 游戏文件栈仍是"下载完直接覆盖目标"。
- 文件体量失控：DownloadViewController 5944 行（五合一）、ModpackImportService 2745 行、ModsManagerViewController 1296 行，审查/测试成本高，建议按资源类型拆分。

## 五、值得肯定的设计亮点
1. PLDownloadClient：镜像候选列表 + 单候选指数退避（1/2/4s）+ 聚合错误（userInfo 带各候选错误数组）、失败负 delta 回退保证进度单调、增量命中零流量、zip EOCD 兜底校验、流式 SHA1、独立 delegate 对象破除 session 强引用环 + dealloc invalidateAndCancel、generation 计数器丢弃过期回调——教科书级。
2. DownloadTaskManager 并发槽位：rawTask=nil 的聚合卡片不占槽位、幂等 release 防信号量超发，注释把"为什么"写透了。
3. DataTransferService：zip-slip 全量条目校验（本仓唯一）+ staging 目录 + 逐文件 move 合并 + 自研 zip 写器（worker 并行读/串行写/预算背压/dlsym zlib，fd 全部正确 close）。
4. ModpackImportService：五格式识别（Modrinth/CF/MMC/MCBBS/PlainZIP）、Task95 import_report.json 持久化完整性报告、Task224 重导入前 saves/截图/配置备份且"任一备份失败即中止删除"、404-skip 与 fail 分离、CurseForge 延迟解析把 HEAD 请求移进并发槽。
5. CurseForgeMurmurHash：空白字节过滤变体的算法验证过程完整记录在注释（含实测指纹），可复现可审计。
6. Task187 看门狗、Task70/71 自愈链路：对"用户卡在验证完整性/JSON 丢失"类顽疾做了防御性收敛。

## 六、审查文件清单
逐行/逐段通读（26）：DownloadTaskManager.m、DownloadTaskItem.m、DownloadHistoryStore.m、PLDownloadClient.m、MinecraftResourceDownloadTask.m、MinecraftResourceUtils.m、ModService.m、ModItem.m、ModUpdateService.m、WorldService.m、WorldItem.m、ModpackImportService.m、ModpackExportService.m、DataTransferService.m（核心导入/导出/zip 写器段）、ModpackUtils.m、CurseForgeMurmurHash.m、installer/modpack/CurseForgeAPI.m（key 链路）、PLPreferences.m（key 链路）、FileListViewController.m、ModLoaderIconHelper.m、ModsManagerViewController.m（更新链路）、installer/ForgeInstallViewController.m（下载链路）、DownloadViewController.m（网络/下载/安装链路）、ResourcePackService.m（目录解析+下载段）、DataPackService.m（目录解析+下载段）、ShaderService.m（下载封装段）。
模式扫描（rg 定向：网络调用/信号量/整文件读/删除与备份/observer/weakSelf，未逐行）+ 差异比对：DownloadTasksViewController.m、DownloadHistoryViewController.m、DownloadTaskItem.h、ModTableViewController.m、ModTableViewCell.m、ModVersion.m、ModVersionViewController.m（与 Shader 版 diff）、ModVersionTableViewCell.m、ModLoaderIconHelper.m、ModsManagerViewController.m（其余段）、ShaderItem.m、ShaderVersion.m、ShaderVersionViewController.m、ShaderVersionTableViewCell.m、ShadersManagerViewController.m、ResourcePackItem.m、ResourceListViewController.m、ResourceCardTableViewCell.m、ResourcePacksManagerViewController.m、DataPackItem.m、DataPacksManagerViewController.m、DataExportViewController.m、ModpackImportViewController.m、ModpackExportViewController.m、CurseForgeAPIKeyViewController.m（两份 diff）、installer/CurseForgeAPIKeyViewController.m、installer/ForgeInstallSchemeViewController.m、installer/ModpackInstallViewController.m、WorldsManagerViewController.m、FolderBrowserViewController.m、AssetVersionViewController.m、AssetDetailHeaderView.m、installer/ModpackInstallViewController.m。
Worklog 已按"先读再追加"写入本文件。
---
Task ID: 2-e-1
Agent: Explore(installer模块)
范围：Natives/installer/ 全部 32 个文件（安装器核心 FabricUtils / ForgeDirectInstaller / NeoForgeDirectInstaller / ForgeProcessorExecutor / NeoForgeVersionFetcher + 6 个 VC + modpack/ 子目录 10 文件），约 1.2 万行。只读审查（五维：清单解析/下载校验/processor 链/路径安全/内存线程）。

## 1) 逐文件问题清单

### P0
无（未发现必然崩溃/构建必败缺陷）。

### P1（4 条，附修改前后对照）

1.【P1】installer/modpack/ModrinthAPI.m:410-424/433-439 — ame217 递归 block 未加 __block，自我捕获值为 nil → Task217 重试是死代码，且首次传输/解析失败后 completion 永不回调（搜索 UI 永久加载、无错误提示）。
   `void (^ame217_attempt)(NSInteger) = nil; ame217_attempt = ^(NSInteger attempt){ ... ame217_attempt(1); ... }`：block 字面量在 RHS 求值时按 const 拷贝捕获 ame217_attempt（此时 = nil），attempt==0 失败路径 dispatch_after 后调 nil block = 无操作，completion 丢失。MCIM 镜像"时好时坏"（同 Task217 病历）时用户侧从"重试一次"退化为"卡死"。
   修前：`void (^ame217_attempt)(NSInteger) = nil; ame217_attempt = ^(NSInteger attempt) {...}; ame217_attempt(0);`
   修后（推荐改方法递归，顺带消除 block 自持环）：`- (void)ame217_attempt:(NSInteger)attempt url:(NSURL *)url completion:(...)completion { ... dispatch_after(..., ^{ [self ame217_attempt:1 url:url completion:completion]; }); }`；或最低成本 `__block void (^ame217_attempt)(NSInteger); ame217_attempt = ...` + completion 前置 `ame217_attempt = nil` 防自持环。

2.【P1】installer/ForgeProcessorExecutor.m:283-302（配合 :52-58、main_hook.m:337）— headless JVM 20 分钟等待超时路径两个竞态：① 超时后 runProcessorsWithProfile 返回，栈上 ame145_ctx 销毁，而 detached JVM 线程仍持 &ame145_ctx 并在最终完成时写 ctx->ret（:54）→ 栈内存 use-after-scope 写（潜在损坏调用栈）；② :300 无条件 `atomic_store(&g_ame_suppressJvmExit, 0)` 清抑制标志，但 JVM 线程还活着——其后 libjli dummyTimer 线程调 exit(0) 时（main_hook.m:337 仅在 flag=1 时才转 pthread_exit）不再被抑制 → 整个 app 延迟闪退（Task144 病历复活，只是晚 20+ 分钟）。触发条件：processor 实际执行 > 20 分钟（低配机 + 大型整合包 mcer 打补丁可及）或 finished 信号漏置。
   修后：ctx 改堆分配并由 JVM 线程 free（或 static/单例）；超时路径不清 suppress 标志，改为由 ame145_headlessJvmThread 退出时自清（该线程是唯一消费者）；读 ctx->ret 前置 finished 检查。

3.【P1·安全】installer/modpack/ModpackUtils.m:8-34（实弹调用点 ModpackImportService.m:1265/1271）— overrides / client-overrides 解压 zip-slip：fileInfo.filename 未做路径清洗，`fileName = [filename substringFromIndex:dir.length+1]; destItemPath = [path stringByAppendingPathComponent:fileName]`，恶意整合包 zip 条目 "overrides/../../Documents/evil" 即写穿目标目录（整合包是用户侧不可信输入：本地导入/第三方站下载）。与 2-a 已审 SSZipArchive._sanitizedPath 形成双标准。
   修前：`NSString *fileName = [fileInfo.filename substringFromIndex:dir.length+1]; NSString *destItemPath = [path stringByAppendingPathComponent:fileName];`
   修后：`NSString *fileName = [[fileInfo.filename substringFromIndex:dir.length+1] stringByReplacingOccurrencesOfString:@"\\" withString:@"/"]; if ([fileName hasPrefix:@"/"] || [[NSString pathWithComponents:fileName.pathComponents] containsString:@"../"]) { *stop = YES; return; } NSString *destItemPath = [path stringByAppendingPathComponent:fileName]; if (![destItemPath hasPrefix:[path stringByAppendingString:@"/"]]) { *stop = YES; return; }`（或直接换 SSZipArchive 带 symlinksValidWithin 的解压入口）。

4.【P1】installer/ForgeDirectInstaller.m:897-1022 + NeoForgeDirectInstaller.m:775-898 — downloadMissingLibraries 下载所有 Forge/NeoForge 运行时库与 processor 工具链库**零完整性校验**：version JSON `downloads.artifact.sha1/size` 字段就在手上从未读取；BMCLAPI 镜像 stale/截断/HTML 错误页（HTTP 200）静默入库 → 启动期 NoClassDefFoundError/ZipException。与同模块 ForgeProcessorExecutor（原版 jar/mojmaps/outputs 全 sha1 校验，:866-878）双标准；2-f 从下载栈角度也点名 installer 无 SHA1。
   修后（下载成功后）：`NSString *expected = [artifact[@"sha1"] isKindOfClass:[NSString class]] ? artifact[@"sha1"] : nil; if (expected.length == 40) { NSString *actual = [ForgeProcessorExecutor sha1OfFile:destPath]（需公开该方法或抽公共工具）; if (![actual caseInsensitiveCompare:expected] == NSOrderedSame) { [fm removeItemAtPath:destPath error:nil]; 走 fallback 源; } }`。

### P2（安全/健壮性/质量，按文件）

5.【P2·安全】ForgeDirectInstaller.m:836-891 + NeoForgeDirectInstaller.m:715-770 extractAllMavenEntries — maven/ 前缀条目同样未清洗 "../"（zip-slip 第二处 sink；installer jar 经 BMCLAPI 等镜像下载且无 sha1 校验，镜像被污染即任意写）。
6.【P2·安全】ForgeDirectInstaller.m:932-948 / NeoForge:810-826 + mavenPathToRelativePath:1376-1381/1191-1195 — 坐标解析：parts<3 时原样返回整串当相对路径；groupId/artifactId/version 及 downloads.artifact.path 均不过滤 ".."、":" → 恶意 version.json 可在 librariesDir 外落文件（与 processor 输出路径 parseLiteral 结果同样未约束）。建议统一坐标→路径后校验每段非空且不含 ["/","\\",".."]。
7.【P2】modpack/ModpackConfiguration.m:35-44 initWithDictionary — `dict[@"downloads"][0]`、`dict[@"hashes"][@"sha1"]` 未验型：downloads 为字符串时 objectAtIndexedSubscript → NSInvalidArgumentException 崩溃（畸形整合包 manifest 即崩）；且 validate()（:23-33）只查 path/hash 不查 downloadURL，无下载源条目静默通过。
8.【P2】ModpackInstallViewController.m:92-94 + 234-267 — ① self.list（nonatomic NSMutableArray）在全局队列赋值、主线程 numberOfRowsInSection/cellForRow 读取 → 数据竞争（翻页时 reloadData 撞上新页赋值）；② showDetails 的 UIAction handler 捕获 indexPath，回调时再取 self.list[indexPath.row]——搜索刷新/翻页后列表已变 → 越界崩溃 + cell 强引用滞留。建议：列表状态收主队列；handler 内改捕获 item 字典本身。
9.【P2】FabricInstallViewController.m:198 + 336-346 — ① response[@"id"]（Fabric meta / 镜像返回）未清洗即拼 `$POJAV_GAME_DIR/versions/{id}/{id}.json` 写入路径；② Fabric API jar 下载（Modrinth 响应带 sha1 却不用）后 `moveItemAtURL:...error:nil`：目标已存在时移动失败被吞仍报安装成功（旧版残留）；③ :186 `[NSString stringWithFormat:endpoint[@"json"], ...]` 格式串来自字典（当前 app 内常量，安全，但模式与 2-a P2#8 同源，译文/配置化后会炸）。
10.【P2】modpack/ModpackAPI.m:24-41 + CurseForgeAPI.m:433-493 getEndpoint/postEndpoint — dispatch_group_wait(group, DISPATCH_TIME_FOREVER) 无兜底超时：AFNetworking 正常路径会回调，但 task 永不回调（被 cancel 且 AF 早期返回等边界）即调用线程永久挂起；另 CurseForgeAPI.getEndpoint 重试循环中 result==nil 且 failure==nil（理论上成功回调 nil obj）会白跑第二轮。建议与文件内其他下载点统一 15-30s 超时。
11.【P2】ForgeProcessorExecutor.m:295-299 — pthread_create 失败兜底回退"同线程 inline 执行"：这正是 Task146 已定性挂死的形态（调用线程为非主线程 → suppress 生效 → JLI 内部 pthread_exit 永不返回 → 轮询线程挂死、安装永久卡住）。pthread_create 失败罕见但该兜底等于复装已知缺陷，建议改为直接报错返回（ErrorLaunchFailed）。
12.【P2】NeoForgeDirectInstaller.m:485-610 ensureParentVersionExists — 与 Forge 版（:327-431，已升级 PLMirrorCenter 候选 + 3 次退避重试）双写漂移：仍是"单源单次请求 + 手工 bmclapi 字符串替换"，镜像故障即安装失败。P2-13 的抽象可一并消除。
13.【P2·质量】ForgeDirectInstaller.m 与 NeoForgeDirectInstaller.m 约 1100 行 90% 逐字复制（downloadMissingLibraries / extractAllMavenEntries / dataFromZip / extractFile / downloadFileFromURL / buildMavenURLForLibrary / buildFallbackURLForLibrary / isCriticalLibrary / mavenPathToRelativePath / ensureParentVersionExists），且已实际分叉（上条、isCriticalLibrary 前缀表两份不一致、Task188 建目录一处用 ensureDirectoryExists 一处直接 ame188_ensureDirectoryHealed）。建议抽 ForgeLikeDirectInstaller 基类 + 差异点（maven 路由表/versionId 推断）子类化。
14.【P2·质量】ForgeInstallViewController.m:331-446 与 NeoForgeVersionFetcher.m:71-115 — NeoForge 版本列表拉取两份实现（VC 内嵌 fetchFromSource 递归回退 vs Fetcher 类），行为可漂移；Fetcher 版 allVersions 有 @synchronized 而 lastError 裸写（:86/:92 等，多线程回调竞争）。

### P3（次要/卫生）
- ForgeProcessorExecutor.m:1143-1154 sha1OfFile：@catch 内 closeFile + @finally 再 closeFile 双重关闭（NSFileHandle 重复 closeFile 可能抛异常/关到复用 fd），删 @catch 内那次即可。
- ForgeProcessorExecutor.m:219/301 pollDone 裸 BOOL 跨线程读写（注释已声明刻意接受；建议 atomic_bool 或 dispatch_queue flag，成本为零）。
- NeoForgeVersionFetcher.m:243-250 extractMinecraftVersionFromNeoForgeVersion if/else 两分支表达式完全相同（死分支）；:254-258 兜底正则对 "1.20.1-xxx" 形态会产出 "1.1.20"（仅在前 main 解析失败时触达，低危）。
- modpack/CurseForgeAPI.m:589-593 Task175 注释 mojibake（UTF-8 双重编码乱码，应重写）。
- modpack/CurseForgeAPI.m:782-829 同步 loadDetailsOfMod 循环 pageSize=10000 + getEndpoint FOREVER 等待——重响应 + 长阻塞，当前调用方已迁异步版，建议标注 deprecated。
- modpack/CurseForgeAPI.m:975 空体重试 reason 恒打 "empty 5xx body"（非 5xx 空体时日志误导）。
- modpack/ModrinthAPI.m:544-577 _searchServerWithProjectType 不检查 HTTP 状态码，4xx/5xx JSON 错误体落为"空结果静默成功"（对比同文件 CurseForge 侧 Task169 已修同类问题）。
- modpack/ModrinthAPI.m:278 `[response[@"files"] firstObject][@"url"]` files 未验型（畸形响应崩溃；可信 API 低风险）。
- ForgeDirectInstaller.m:174 / NeoForgeDirectInstaller.m:160 dispatch_sync(main) 注册 profile——当前调用链主线程不等待安装线程故不触发，但属 2-a 点名的同款死锁敞口，建议 dispatch_async（注册顺序无下游依赖）。
- modpack/ModpackUtils.m:140 writePlaceholderVersionJSON `[NSString stringWithFormat:@"%s/versions/%@", getenv("POJAV_GAME_DIR"), versionId]`：env 为 NULL 时 %s UB；versionId（来自整合包 manifest 依赖字段拼接）未清洗即拼路径。
- FabricInstallViewController.m:16 `extern NSMutableArray *localVersionList` 跨模块可变全局（environ.h 全局黑板同款问题的 ObjC 版）。
- installer/CurseForgeAPIKeyViewController.m:541/569 两处状态文案硬编码中文未走 localize（同文件其余均 localize）。
- 大方法：runProcessorsWithProfile ~280 行、installNewFormat（Forge/Neo）~220 行，建议按 6 个内部步骤拆分（注释分步已就绪，拆分成本低）。

## 2) 安装器健壮性专项评级

| 维度 | 评级 | 说明 |
|---|---|---|
| 版本清单解析健壮性 | A- | 全模块 isKindOfClass 层层验型、畸形 JSON 走错误路径不崩（Executor/DirectInstaller 尤佳）；扣分：ModpackConfiguration 下标（#7）、Modrinth 同步 hits 未验型 |
| 下载校验 | C+ | Executor 侧全 sha1+失败删除重下（优）；DirectInstaller 双双零校验（#4）、Fabric API 无校验、installer jar 无校验（2-f 亦证） |
| processor 执行链安全 | B | 无 shell 拼接（args 数组经 commands.json 契约到 Java 侧逐条调用）、20min 超时上限、错误码完整、断点续装；扣分：超时路径两竞态（#2）、inline 兜底复装挂死（#11） |
| 路径安全 | C | overrides zip-slip（#3）+ maven/ zip-slip（#5）+ 坐标/manifest 路径未清洗（#6/#9）三处写穿面；对比 SSZipArchive 的 sanitizedPath 属明显欠账 |
| 内存与线程 | B- | 轮询/进度 block 生命周期、weak/strong 使用普遍正确，@autoreleasepool 齐全；扣分：ame217 自捕获（#1）、self.list 跨线程（#8）、lastError 裸写（#14） |

**综合：B**（无 P0、4×P1；P1 全部为小改可修：#1 一行 __block/改方法、#2 十行内、#3 一个清洗函数、#4 复用现成 sha1OfFile。修复后可达 A-）。

## 3) 设计亮点
- **ForgeProcessorExecutor 的 headless JVM 序列化方案**是 iOS 沙箱（禁 fork/exec）下的独创解：processors 序列化为 commands.json → 进程内 JVM ForgeProcessorRunner 逐条执行 → status.json 回传。Task144/145/146 三轮病历注释（exit 抑制 → 专用线程 → finished 信号）完整记录了从"装 Forge 闪退"到"进度 85% 刷屏"到最终方案的设计演进，是本仓"病历文化"的典范。
- 断点续装：outputs 全 sha1 满足即跳过 + 损坏产物自动删除重建（:482-486/:580-598）。
- Task188 后置产物校验（存在性 + PK\x03\x04 魔数）在 processor 跑完后定案，根治"安装报成功但启动缺件"的静默失败（Forge/Neo 双侧同款）。
- replaceTokens/parseLiteral 从 ZL2 的严谨移植：`\` 转义、未闭合 `{`/`'`、缺失变量全部显式报错，args 逐字面量解析不静默吞。
- CurseForgeAPI Task169/171/172/211/212/173/179 系列：网关错误形态识别（HTTP 200 + 无 data）、瞬态 5xx/空体/网络错误退避重试、keyless 强制 MCIM 镜像回退、占位 key 垃圾家族表（含 "((void *)0)"）三方共用、403 友好化指路设置页——把"时好时坏"类网络顽疾系统性收敛，诊断日志（脱敏 key、snippet、hex 兜底）到位。
- PLMirrorCenter 统一镜像候选抽象被 FabricUtils/ModLoader URL/Modrinth/CurseForge 四处一致消费（含 mcim/bmclapi 意图归一），策略单一出口。
- ModLoaderInstallViewController Task185 竞速 + 结果验证（陈旧镜像 maven-metadata 挤掉官方源问题）与 ame185_loaderVersionMatchesGameVersion 跨纪元版本匹配。
- 占位 version JSON（mainClass 指向不存在类）让加载器直装失败显式暴露而非伪装 vanilla。

## 4) 审查文件清单
完整读完（15）：ForgeProcessorExecutor.m、ForgeDirectInstaller.m、NeoForgeDirectInstaller.m、NeoForgeVersionFetcher.m、FabricUtils.m/.h、modpack/ModpackUtils.m、modpack/ModpackAPI.m/.h、modpack/ModpackConfiguration.m/.h、modpack/ModrinthAPI.m、modpack/CurseForgeAPI.m/.h、ModpackInstallViewController.m、FabricInstallViewController.m、ForgeInstallSchemeViewController.m。
抽查（定向段 + 方法清单扫描）：ForgeInstallViewController.m（约 40%：元数据拉取/竞速/下载与统一进度段 300-600、1130-1280）、ModLoaderInstallViewController.m（约 30%：版本加载/XML 解析段 640-1130 + rg 方法面）、CurseForgeAPIKeyViewController.m（key 保存/测试链路 504-633 + rg 方法面）、ForgeProcessorExecutor.h、ForgeDirectInstaller.h、ModLoaderInstallViewController.h、modpack/ModrinthAPI.h、modpack/ModpackUtils.h、modpack/ModpackConfiguration.h。
调用面核对（跨文件，只读）：DownloadViewController.m:4161-4189（直装线程/进度桥接）、ModpackImportService.m:1265/1271（overrides 解压 sink）、ServerService.m:143（CF 异步详情）、MinecraftResourceUtils.m:96-118（evaluateRules OS 判断：allow/disallow/最后匹配胜出语义正确，features 规则保守禁用）、utils.m:1135（ame188_ensureDirectoryHealed）、main_hook.m:337-346（suppressJvmExit/headlessJvmFinished 语义，用于 #2 定案）。

结论：无 P0；P1×4（ame217 死重试丢回调、processor 超时双竞态、overrides zip-slip、直装库零校验）建议本轮修复；P2×10 中 #12/#13/#14 属复制分叉债（与 2-f 的"下载栈 5 套"观察同源），其余为输入信任边界缺口。与 2-a/2-b/2-f 结论互洽：本模块防御性工程优于同体量 fork，主要短板在"下载完整性校验只在 Executor 一处"与"installer zip 条目路径零清洗"两个系统性缺口。

---
Task ID: 2-e-2
Agent: Explore(Java端与桥接)
范围：JavaApp/src 全部 76 个 java 文件（启动流程/认证注入/控制桥接/AWT-Caciocavallo 影子桩优先精读）+ Natives/customcontrols 全部 14 个文件（控件布局 JSON 解析与坐标数学）+ Natives/ctxbridges 全部 14 个文件（GL/OSM/VK/VirGL/FSR 桥），只读。

## 1) 逐文件问题清单

### P1（3 条）
1.【P1】ctxbridges/osm_bridge.m:1081/1139/1254/1286 osm_swap_buffers / osm_apply_current_ll —— br_get_current() NULL 解引用。Task147 只修了 osm_make_current(NULL) 分支（:1095-1114，Run #356 装机 hs_err 实锤的同类崩溃），swap 路径漏修：SDL3 接管后 swap 调用时序不再受 GLFW 约束（gl_swap_buffers:2205-2212 的防护注释原文自证该时序存在），MakeCurrent 之前/释放之后调 swap 即 SIGSEGV。同函数 :1170 的 Task105 块却做了判空——同文件内自相矛盾。
   修前：`osm_apply_current_ll()` 直接 `br_get_current()->osm.width`；`osm_swap_buffers()` 直接 `br_get_current()->osm.buffer`（4 处）。
   修后：osm_swap_buffers 入口 `basic_render_window_t *cur = br_get_current(); if (cur == NULL) { NSLog(@"OSMBridge: swap with no current context, ignored"); return; }`（与 gl_swap_buffers 同款），函数体统一用局部 cur；osm_apply_current_ll 增加 bundle 参数或同样判空。

2.【P1】customcontrols/CustomControlsUtils.m:553-566 + ControlLayout.m:85-97 —— 畸形（JSON 合法但形状错误）控件布局 → "半初始化按钮滞留视图树" → 之后每次布局必崩。
   链路：loadControlObject 的 @try 内 `addSubview`（:557）先于 `[button update]`（:558）；update→calculateDynamicPos 遇 dynamicX 非 NSString/非法 NSExpression 抛异常，@catch 吞成 errorString 但按钮已入树；ControlLayout.setFrame:88-93 对每个 ControlButton【无 @try】调 update → 下一帧布局重抛未捕获异常 → 启动器崩。同函数还有两个无防护面：:582-598 子按钮（ControlSubButton buttonWithProperties / drawerData[@"buttonProperties"] 迭代）完全无 @try；:550 convertLayoutIfNecessary 对 mControlDataList 为 NSString/NSDictionary 的类型混淆 casting 后直接快速枚举与下标（NSString 可枚举出 NSNumber → setObject:forKeyedSubscript: unrecognized selector）。
   修后：① @catch 中补 `[button removeFromSuperview]`；② 子按钮循环与 convert 循环补 @try（与主按钮同口径）；③ 三条 list 迭代前 `isKindOfClass:[NSMutableArray class]` 验型，元素验 NSDictionary。

3.【P1】launcher/Tools.java:543 appendServerArgs —— `versionId.compareTo("1.20") < 0` 字典序版本比较：MC 1.2.x–1.9.x（"1.9"/"1.8" 字典序 > "1.20"）被误判 ≥1.20 → 追加 `--quickPlayMultiplayer`（1.20 才有）→ 老版本 joptsimple 对未知参数抛异常 → FCL 风格自动进服场景启动即崩。同根问题：PojavLauncher.java:308-312 语言选择 `compareTo("1.11")`（1.2–1.9 被判 ≥1.11 → 写小写 zh_cn；其自注释明言 1.1–1.5 小写会崩 → 1.2–1.5 首启即崩）。
   修后：抽语义比较（同文件 ame171IsMc264OrLater:465-478 已有 regex+数字解析先例）：
   ```java
   // 修前：if (versionId.compareTo("1.20") < 0) { --server/--port } else { --quickPlayMultiplayer }
   // 修后：int[] v = ameParseMajorMinor(versionId);   // ^(\d+)\.(\d+)
   //       boolean quickPlay = (v[0] > 1) || (v[0] == 1 && v[1] >= 20);
   ```

### P2（安全/健壮性，11 条）
4.【P2】ctxbridges/gl_bridge.m:2266-2278 gl_terminate —— 三连：① `br_get_current()` 无判空（未 make_current 的线程/已释放后调 terminate → NULL 解引用，与 P1#1 同类，gl_swap_buffers 有防护而它没有）；② `free(br_get_current())` 释放的是"调用线程 TLS 指到的 bundle"而非本次会话 bundle——跨线程 terminate 时释放错对象 + 本会话 bundle 泄漏；③ Task193 层→表面单例（:1901-1928 static s_ame193_layerSurface）与 g_ame48_layer_cf（:1291-1318 CFBridgingRetain）terminate 后不复位：同进程重启游戏会话时旧 surface 已被 eglTerminate 销毁，:1906 仍复用陈旧 EGLSurface 句柄 → eglMakeCurrent EGL_BAD_SURFACE。
   修后：terminate 判空；init_context 时把 bundle 记入 static 会话指针并在 terminate 释放该指针；terminate 内 CFRelease(g_ame48_layer_cf)=NULL、s_ame193_layerSurface=EGL_NO_SURFACE。

5.【P2】customcontrols/CustomControlsUtils.m:46-61 convertUIColor2ARGB/convertUIColor2RGB —— `CGColorGetComponents` 未查分量数：灰度空间颜色（[UIColor whiteColor]/拾色器 grayscale，2 分量）读 rgba[1..3] 越界（UB）且换算错误（白色被持久化成错值 ARGB）。取色编辑器往返即触发。
   修后：`switch (CGColorGetNumberOfComponents(color.CGColor))` 分派：2 分量 → r=g=b=comp[0]、a=comp[1]；4 分量走现路径；其余 NSLog 兜底 0xFF000000。

6.【P2】ctxbridges/osm_bridge.mm:143-145 —— `#define GL_READ_FRAMEBUFFER 0x8CA9` 与 GL_DRAW_FRAMEBUFFER 同值（规范值 0x8CA8）：:773-776/:1047-1049 的状态还原 `glBindFramebuffer(GL_DRAW_FRAMEBUFFER, saveDrawFbo); glBindFramebuffer(GL_READ_FRAMEBUFFER, saveReadFbo);` 实际对 DRAW 绑定连写两次（第二次用 saveReadFbo 覆盖），READ 绑定从未还原。当前 MC 流 read==draw 故良性，属模组非对称绑定时还原错误 + DRAW 被污染的潜伏雷。mgl_fsr.mm:120-125 同病（GL_DRAW_FRAMEBUFFER_BINDING 错值 0x8CA9，应为 0x8CA6），但该链体已 #if 0 退休（:868）仅存档。

7.【P2】ctxbridges/osm_bridge.mm:1504-1579 —— swap 尾部 dispatch_async(main) 的 CGImage 包装闭包捕获裸指针（cropSrc=ame100_present.present、bundle.buffer）：主线程执行前渲染线程因尺寸变更 realloc（osm_apply_current_ll:1087 reallocf / :1014-1022）→ 悬垂指针被 CGImageCreate 读取。旋转/分辨率切换的帧窗口可触发。
   修后：闭包内先 memcpy 到 provider 自有内存，或 CGDataProviderCreateWithData 传 release 回调转移所有权。

8.【P2】ctxbridges/osm_bridge.mm:1118 osm_make_current —— `color_space = CGColorSpaceCreateDeviceRGB()` 每次调用新建不释放旧值（Task146 日志证明 make-current 多次发生）→ CGColorSpace 泄漏。修后：赋新前 `CGColorSpaceRelease(cur->osm.color_space)` 或仅 bundle 首次创建。

9.【P2】launcher/PojavLauncher.java:198-206 Forge splash.properties 禁用逻辑写错对象：`Tools.read(path.replace("enabled=true","enabled=false"))` —— replace 作用于【路径】而非【内容】（路径不含该子串=恒等），已存在的 splash.properties 原样写回，enabled=true 永远清不掉（上游 PojavLauncher 同源 bug 随移植带入；不存在分支写入 "enabled=false" 正确）。修后：`Tools.write(path, Tools.read(path).replace("enabled=true","enabled=false"))`。

10.【P2】lwjgl/GLFW.java:523/1197-1199 glfwGetKey —— `keyDownBuffer.get(Math.max(0, key-31))`，buffer 容量 317：GLFW_KEY_MENU(348) 及任何 >347 键 → IndexOutOfBoundsException → 渲染线程异常 → P2#13 的 exit(1) 等效崩游戏。与 2-a P2#15（input_bridge_v3 native 侧同款）互为镜像。修后：`int idx = key - 31; return (idx >= 0 && idx < keyDownBuffer.capacity()) ? keyDownBuffer.get(idx) : 0;`

11.【P2】ctxbridges/bridge_tbl.h:18-25 —— 六个桥接函数指针（br_init/br_init_context/br_make_current/br_swap_buffers/br_swap_interval/br_terminate）在头文件【定义】（tentative def 靠 -fcommon 合并）：与 2-a P2#9（JavaLauncher.h/utils.h）同族未爆雷，-fno-common 即链接失败。修后：extern 声明 + set_*_bridge_tbl TU 单一定义。

12.【P2】customcontrols/CustomControlsUtils.m:85-113 convertV2Layout —— 坐标单位不对称：dynamicX 分母是【像素】宽（(bounds-insets)×scale），dynamicY 分母是【点】高（bounds.size.height）。若 V1/V2 存量 x/y 同为像素（上游 Android 口径），y 相对量被缩小 scale 倍（控件向顶聚集）；若存量本为点则 X 反向偏差。仅影响 ≤V2 老布局（Task198 已挡误盖低版本号），建议实机载入一份 V2 存量核对后统一口径。

13.【P2】launcher/PojavLauncher.java:37-43 —— 主线程 UncaughtExceptionHandler 直接 `System.exit(1)`：启动期任何异常绕过 UIKit.showError（native 侧弹窗基础设施齐全）直接杀进程，用户只见闪退。修后：handler 内先 UIKit.showError(栈摘要) 再 exit。

14.【P2】customcontrols/CustomControlsUtils.m:370-373/442-445 —— generateAndSaveDefaultControl/ForGamepad 的 `NSJSONSerialization writeJSONObject:error:nil` + NSOutputStream 不查状态：磁盘满/权限异常时 default.json 静默缺失（目录创建已由 main.m:337-345 覆盖 ✓），Task64 回落链随之失效成"零控件"。修后：检查返回值与流状态，失败 NSLog 留痕。

### P3（次要/卫生，20 条）
- Tools.java:877-885/916-924 convertStream/read(InputStream)：`out +=` 循环拼接 O(n²)+512B 缓冲（version.json 启动路径）；改 StringBuilder/8192。
- Tools.java:930-939 write：BufferedOutputStream 异常路径无 finally，fd 泄漏。
- Tools.java:698/705 preProcessLibraries：`name.split(":")[2]` AIOOBE（畸形坐标）、parseInt NFE（"5.13.0-beta" 类版本）无防护；artifactToPath:585-586 忽略 classifier 段。
- Tools.java:895-914 lastFileModified：listFiles 为 null（目录不存在）→ NPE。
- JMinecraftVersionList.java:56-67 ArgValue/ArgRules 死代码：arguments.game 声明为 Object[]，Gson 从不实例化 ArgValue；注释块 cast 一旦复活即 ClassCastException，且 `public String features` 与真实 JSON 的 features 对象冲突。1.13+ 规则参数（--demo/--width/--height）被静默丢弃——已由 --demo 注入（Tools:569-571）与 overrideWidth/Height（PojavLauncher:67-68）补偿，建议删注释块并留说明。
- MCOptionUtils.java:68-77 remove() 只删首个匹配（set():44-49 已 Task104 全量去重）——"清除 graphicsApi"遇历史双行残留会留下旧行（MC 后行覆盖语义使清除失效）。
- MCOptionUtils.java:10-30 静态 mLineList 无同步（当前单线程启动链无症状）。
- PojavLauncher.java:50 args[0] 无长度检查（空参数 AIOOBE）；:62-64 cacio.managed.screensize 为 null 即 NPE；GLFW.java:532 glfw.windowSize NPE、:551 UIScreen.maximumFramesPerSecond parseInt NFE——四个"native 未喂属性即崩"的静态初始化地雷（native 恒设置，jar 直启路径脆弱），建议各自兜底。
- GLFW.java:526-531 static 块 System.load 失败仅 printStackTrace 继续 → 后续 Functions/natives 全链 UnsatisfiedLinkError 且首因日志被淹；与 UIKit.java:79-81 的无 catch 样式相反，宜统一"loud fail 单点"。
- GLFW.java:1437-1441 glfwExtensionSupported contains 子串匹配（前缀同名扩展误报，注释自认）；:806 每次 glfwInit new Throwable 栈嗅探；:926-929 glfwSetWindowMonitor `window * monitor` 伪指针乘法；mGLFWWindowMap/mGLFWKeyCodes 跨线程裸 ArrayMap（上游同源）。
- Narrator.java:68-71 setJNAPath 在 jna.library.path 未设时拼出 "null..."（无调用方，防御缺角）。
- LWJGLGLFWKeycode.java 全类无引用——第三份 GLFW 键码常量死代码（与 GLFW.java、glfw_keycodes.h 三重复制）。
- PatchJNAAgent.java:17-20 / PatchSVC.java:39-42 以 available() 定长 + readFully（jar 资源流凑巧成立，非契约保证）。
- android/util 五文件与 org.lwjgl.ame 五文件 1651 行逐字节复制（仅包名行不同；Task189 有明确理由）——建议构建期从单一源生成，消除手工双维护。
- ControlJoystick.m:155-159 ame67HeartbeatTimer target:self——touchEnd/Cancelled/编辑模式三路 invalidate ✓，但布局重载（removeAllButtons）发生在触摸进行中时定时器无主（泄漏+空转发心跳）；建议 block timer + weak。
- virgl_server.m:342 错误日志 ret 恒打占位 0（真实 eglChooseConfig 返回值未捕获，取证误导）；:86 ame_vs_started 裸 int 非原子；引导失败路径（return -1/-2）遗留 display/pbuffer/context 不清理。
- vk_bridge.m:216-219 vk_make_current 未走 br_set_current（bridge_tbl.h:50 的 Task144"写入一律走 br_set_current"约定在 Vulkan 路径缺席；若系有意应注释固化）。
- osm_bridge.mm:1087 reallocf 失败返回 NULL 未查（OSMesaMakeCurrent 收 NULL buffer 行为未定义）；:1586-1588 osm_terminate 空实现——会话退出未走 makeCurrent(NULL) 时 bundle.buffer(~15MB)/colorspace 滞留。
- generateAndSaveCustomControl:459 copyItemAtPath 对已存在目标会失败（有 error 日志 ✓）；CustomControlsUtils createButton/convertARGB2UIColor 无问题。
- 大方法：PojavLauncher.launchMinecraft ~320 行、osm_swap_buffers ~460 行（四代 Task 补丁同函数层叠）——建议按注释分步拆函数（与 2-f 对 installer 的建议同款）。

## 2) Java 端架构观察
- **包结构与分层**：launcher/（启动核心+数据模型）、lwjgl/（LWJGL overlay：GLFW 桩 + 系统类兼容层）、com/apple/ios/audio（javax.sound SPI 桥）、com/mojang/text2speech 与 blaze3d（按 26.x 客户端常量池扫描对齐方法面的影子桩）、patchjna_agent/patchsvc（字节码 agent）。职责清楚："launcher 是策略，lwjgl 是 API 形状补全，com.* 是影子桩"。
- **与上游偏离度**：PojavLauncher/Tools/GLFW 保留上游骨架，但 Amethyst/Prisma 增量约 20 个 Task 修复点内嵌（94/104/86/162/173/196/198/220…）；org.lwjgl.ame 五文件、ThreadLocalUtil 的 JNI_VERSION_24、Callback/CallbackI 双 API 兼容、Version/VersionImpl 动态上报是纯本地发明。"影子桩最小面"纪律好（NarratorMac 注释明确"仅为 API 形状对齐"）。
- **Java/ObjC 职责边界（审查维 2 答卷）**：JVM 创建、-Xmx（Task141/173 双闸，JavaLauncher.m:2236）、全部 -javaagent（patchjna/patchsvc/metallum/arc_dns/authlib-injector——第三方认证经 ThirdPartyAuthenticator getJvmArgsForAuthlib 在 JavaLauncher.m:2571-2586 注入）、全部 -D 注入（cacio.managed.screensize:2778、UIScreen.maximumFramesPerSecond:2300、org.lwjgl.*.libname）都在 native；Java 端零内存参数逻辑、零认证网络逻辑（仅读账户 JSON + Keychain 取 token，MinecraftAccount.parse）。**启动参数无两边重复实现**。真实重复点三处：① guiScale 计算（UIKit.updateMCGuiScale vs native refreshGuiScaleNatively——Task162 注释明确双实现算法一致，有意识冗余，建议注释互指）；② AMETHYST_RENDERER 语义判断两套真源（Java：PojavLauncher contains("vgpu")/"libMoltenVK.dylib" 精确匹配、Tools isMc264OrLater；C：isDesktopGLRenderer/isMobileGLRenderer/isSelfEglRenderer——新增渲染器键需人肉同步 3+ 处）；③ 版本号解析（C 侧 Task94 数字解析 vs Java 三处 compareTo 字典序——P1#3 即其恶果，建议统一到 Java 一个 VersionUtils）。
- **可维护性**：Tools.java(944)/PojavLauncher.launchMinecraft(~320 行策略汤)/GLFW.java(1442) 三大热点；launchMinecraft 混合 options.txt 政策、env 契约读取、log4j 配置、Forge/OptiFine 检测、语言写入——每块都有病历注释但缺函数边界，建议拆 MCOptionsPolicy/EnvContract/LaunchPreflight。env 契约（AMETHYST_RENDERER/AMETHYST_GRAPHICS_API/POJAV_DISABLE_VSYNC/MVK_CONFIG_*）Java 侧 6+ 消费点，与 2-a"env 即 IPC"结论互洽。getMinecraftArgs/generateLaunchClassPath 接近纯函数，天然可单测——当前零测试，VersionUtils+单测是性价比最高的第一步。
- **customcontrols 的"两段式防御"**（解析失败→Task64 回落 default.json ✓；形状错误→部分 @try ✓ 部分 ✗）与 ctxbridges 的取证纪律互为镜子：前者差最后一层验型（P1#2），后者是全仓工程样本。

## 3) 设计亮点
- **ForgeProcessorRunner**：进程内 headless processor 执行器的 Java 半边——parent=platform loader 复刻 IsolatedClassLoader 语义、InvocationTargetException 解包、sha1 断点续跑+坏产物删除重建、status.json 原子写（tmp+rename+copy 兜底）、永不 System.exit。全仓 Java 质量标杆。
- **Task86 启动看门狗**（Tools.startLaunchWatchdog）：两阶段采样+栈签名去重+Task87 弹窗阻塞模式识别（Object.wait-under-app-frames 判据），把"整合包卡死"从玄学变可取证。
- **Task94 LWJGL 版本动态上报链**：version.json 捕获→org.lwjgl.version.report→Version/VersionImpl 同源读取，根治 sodium 版本门误杀；ThreadLocalUtil 为 Java 25 手工补 JNI_VERSION_24（233 函数）并留完整病历。
- **Callback/CallbackI 3.3.x/3.4.1 双 API 兼容层**：default 方法互为兜底，递归死角的触发条件（"两覆盖皆缺才递归"）注释写明。
- **Task198 控件版本误盖救回**：用"keycodes 数组+dynamicX 字符串+无静态 x 三条件不可能同时出现在真 V1"做指纹判定，救回+落戳+日志一次完成——防御性指纹设计的范本。
- **mgl_metal_fsr.mm**：Metal 层 drawable 代理（nextDrawable 重写+8 槽环+信号量 in-flight 防护+250ms 超时+限频丢帧日志+四重门控+teardown 完整）；Task167 对 MoltenVK naturalDrawableSizeMVK（bounds×contentsScale 才是 currentExtent 真源）的逆向定位是本仓逆向功力代表作。
- **gl_bridge/osm_bridge 的病历式取证**：Task58 EGL 宽高常量对调定案（0x3056/0x3057）、Task204 pname 换 0x8CA6、Task49 两段 scratch blit、Task103/104 双哨兵、Task76 取证降频（保护 MobileGlues 错误转译队列）——每个探针都有退役条件与限频纪律，长期不劣化。

## 4) 审查文件清单
完整读完（逐行）：
- JavaApp/src/launcher（26）：PojavLauncher、Tools、PojavClassLoader、ForgeProcessorRunner、MCOptionUtils、JSONUtils、UIKit、UIKitCallback、LWJGLGLFWKeycode、JVersion、JMinecraftVersionList、JAssets、JAssetInfo、MinecraftAccount、DependentLibrary、MinecraftLibraryArtifact、MinecraftClientInfo、ForgeInstallProfile、MacosUtil、Narrator、NativeAudioCapture、IOSAudioMixerProvider、IOSAudioMixer、IOSTargetDataLine、PatchJNAAgent、PatchSVC
- JavaApp/src/lwjgl（12）：GLFW、CallbackBridge、Callbacks、Callback、CallbackI、ThreadLocalUtil、Version、VersionImpl、GLFWWindowProperties、GLFWNativeEGL、GLFWNativeCocoa、InfdevMouse
- Natives/customcontrols（14/14）：ControlLayout、CustomControlsUtils、ControlButton、ControlJoystick、ControlDrawer、ControlSubButton、NSPredicateUtilitiesExternal + 7 头文件
- Natives/ctxbridges（14/14）：gl_bridge.m、osm_bridge.mm、mgl_fsr.mm、mgl_metal_fsr.mm、vk_bridge.m、virgl_server.m、bridge_tbl.h、gl_bridge.h、vk_bridge.h、osm_bridge.h、virgl_server.h、mgl_metal_fsr.h、FSRRCASSource.h（shader 字面量抽读）、osmesa_internal.h（声明区抽读）
抽查（结构+关键函数/头部）：launcherprofiles/ 7 模型、text2speech 其余 7 桩、GLFWVulkan、APIUtil、STBImageResize、patchjna Platform、patchsvc lame4j/opus4j/speex4j/rnnoise4j 7 文件（方法面+加载模式）、android/util 5 文件（与 org.lwjgl.ame 逐字节 diff 验证仅包名差异）。
边界核对（跨文件只读）：JavaLauncher.m（-Xmx:2236 / authlib-injector:2571-2586 / -D 注入 2300/2778 定位）、main.m init_setupCustomControls:337-345（controlmap 目录创建时序）、PLPreferences.m:105-113（Task77 默认布局链）；与 2-a（JavaLauncher/environ）、2-b（SurfaceViewController 触摸链）结论交叉引用不重复计分。

结论：无 P0；P1×3（osm swap 空指针、畸形布局半初始化按钮崩溃链、字典序版本比较双点）均为小改可修；P2×11 按会话影响排序入库；P3×20 录入。Java 端与 native 的职责边界干净（启动参数/认证注入单边归属），主要债务在版本字符串字典序比较、env 契约双真源、以及 customcontrols JSON 形状防御的最后一层缺口；ctxbridges 整体工程质量与 2-a 结论一致——取证纪律是全仓样板，剩余风险集中在 osm_bridge 的生命周期边角（swap 判空、terminate 释放、闭包悬垂）。

---
Task ID: 3
Agent: main (Super Z)
Task: 交叉验证关键结论并汇总最终报告

Work Log:
- 对 7 项关键结论逐一源码验证：CardLayout:47 语法损坏 ✅、Makefile all:clean ✅、ATS 全关 ✅、AI Key 明文 ✅、ModpackUtils zip-slip ✅、CI 无 RELEASE=1 ✅、timeout 86400 ✅、TXM 未初始化 ✅、上帝类行数（SurfaceVC 3733/DownloadVC 5944/RightPanel 2156）✅
- 汇总 7 路审查（2-a~2-f + 2-e 拆分重试）输出团队评审报告与 P0/P1/P2 路线图（对话内交付）

Stage Summary:
- 全部审查完成：P0×8、P1×20+、P2×30+；四大方向专项结论与优化路线图已交付用户

---
Task ID: 4
Agent: main (Super Z)
Task: Task240 菜单全面原生 UIMenu 化实施（用户指令"你来改吧。要改全部"）

Work Log:
- 读取仓库 worklog（Task223-239 闭环），对齐远端 5282a9e
- 新组件 AmeNativeMenu（UIContextMenuInteraction + presentMenu + 字典协议 + onDismiss），34 处菜单/选择器换装（19 文件），Task227 自绘菜单与 JRE 私有 API 双轨退役，4 处确认类弹窗按"弹窗≠菜单"定案保留
- 发现并核实显示层吞字第四次实证（"缺 [m"假象），撤回此前 P0-1 误报（CardLayout 源码实际完好）
- 验证：task240_syntax_gate（22 文件平衡+退役引用零残留+import 完整）+ task139 + task175 全绿；提交 25dc55b 推送 main（AGENTS.md 署名规范），CI run 38048179233 后台轮询中
- 凭据处理：token 已按仓库惯例配置到 remote URL（.git/config 本地保留，未写入任何被提交文件）

Stage Summary:
- Task240 全链完成待 CI；装机验证锚点已写入仓库 worklog（账号 ⋯/长按系统玻璃菜单、默认皮肤子菜单、设置页 pick 行、游戏内分辨率、角色选择 onDismiss 不卡死）

---
Task ID: 5
Agent: main (Super Z)
Task: Task240 CI 修复梯（r1-r4）至全绿闭环

Work Log:
- r1 07ab378：补齐 withTitle 四参便捷入口（onDismiss 变体）
- r2 2cde447：AmeNativeMenu.m:24 注释续行补 ///（ninja TU 取证掩蔽 + od -c 定案）
- r3 a666f12：presentMenu 类目自声明兜底（CI iOS 26.2 SDK 类目不可见，同域先例 = JRE 旧私有 API）
- r4 589d38c：TouchController 三处 ✓ 前缀表达式补外层方括号（裸 continuation 语法雷）
- run 38051501602 completed success，主提交 25dc55b，闭环提交 e2c160e
- 仓库 worklog 已按 Task224-ci/225-ci 惯例补记 240-ci 段

Stage Summary:
- Task240 全链交付：AmeNativeMenu 组件 + 34 处菜单全量换装系统 UIMenu + CI 四轮终绿，新 IPA 就绪待装机验证

---
Task ID: 241
Agent: main (Super Z)
Task: 装机反馈修复——①悬浮菜单全部打开崩溃 ②新闻磁贴文字重叠（IMG_0373）

Work Log:
- 读 repo worklog 尾部 + Task 240 条目，还原 Task240 全量 UIMenu 换装链路与 38 处 AmeNativeMenu 调用点
- 崩溃定案：AmeNativeMenu presentMenu 类目纯声明无 IMP，真机 iOS 26 无该选择器 → unrecognized selector 全线崩
- 修复三级降级链：presentMenu → _presentMenuAtLocation:（UIKit+hook.h 同域先例）→ actionSheet 兜底 + onDismiss 不悬死（AmeNativeMenu.m/.h）
- 文字重叠三因：100pt 绝对高度 × numberOfLines=0 长摘要溢出 / 描边镜像层溢出态几何同源失效 / 日期右下角绝对定位被文字流盖住
- 修复：HomeNewsTileCell 摘要限 3 行 + clipsToBounds + dateLabel 迁入 textStack（LauncherNewsViewController.m）；swizzle 拷贝矩形溢出即整组跳过（BackgroundManager.m）
- 门禁：task240_syntax_gate / task139 / task175 全 PASS；字符级状态机平衡扫描零残留（粗扫描器把字符串内 https:// 当注释 → 假阳性已排除）
- repo worklog 追加 Task 241 条目；提交 9df3f61 推送 origin main（PAT 已在 remote URL 内保留，未改动）

Stage Summary:
- 9df3f61 已推送，CI 自动出 IPA；崩溃类结构性根除（探测+@try+双后备），鬼影家族第九轮终局（溢出态护栏）
- 待用户装机验证：菜单全量点开 + 主页新闻磁贴长摘要卡片；若仍崩需 latestlog（[AmeNativeMenu] Task241 面包屑已埋）

---
Task ID: 4
Agent: main (Super Z)
Task: 用户报告"错误了"——诊断并修复 Task 241 提交的 CI 失败（悬浮菜单崩溃修复提交被编译错误阻断）

Work Log:
- 核实现状：仓库 HEAD = 9df3f61（Task 241：悬浮菜单崩溃根治 + 新闻磁贴文字重叠，前会话已提交），工作树干净
- 定案：run 38054003971 failure，diag 三错全中 Natives/AmeNativeMenu.m——:79 captured.handler ×2（UIAction.handler 非公开属性，Task240 禁忌被 Task241 自踩）+ :85 C 函数调用误包 [] 当消息表达式（expected identifier）
- 修复：兜底拍平改字典协议直驱 ame240_addDictItemsToAlert（handler 唯一合法来源 = 字典快照）；呈现链加内部四参 dictsForFallback:；Multiplayer 唯一 UIMenu 直构调用点收编字典入口（37 处全统一）
- 未调度集审计：BackgroundManager/LauncherNews 的 Task241 改动未被失败轮编译，人工核验 diff 无雷
- 门禁：task240_syntax_gate / task139 / task158 / task175 全 PASS + .handler 反取全仓扫描零残留
- 推送 955027d → run 38056791753 一轮终绿（ipa/tipa 220.3MB + dSYM）；仓库 worklog 补 Task 241-ci 条目（db246b9）

Stage Summary:
- Task 241 全链闭环：悬浮菜单真机崩溃 + CI 编译雷 + 新闻磁贴文字重叠三案根治，新 IPA 就绪待装机验证
- PAT 保留使用（远端 URL 已含凭据）；下一步 = 用户装机验证 IMG_0370 基准的液态玻璃菜单与磁贴排版

---
Task ID: 5
Agent: main (Super Z)
Task: Task 242 —— 用户装机八连反馈（菜单风格分轨/自动隔离/文字重叠自适应/退出挂起/齿轮球等）

Work Log:
- 取证 28 组定位全部病灶；六项修复 + 两项待日志/截图分诊
- 菜单风格分轨（①②⑥）：AmeNativeMenu 重写——玻璃档 AmeFloatingMenu UIGlassEffect 面板全接管 37 处菜单，原生档 actionSheet 直通；私有三级链退役；AmeFloatingMenu 加 onDismiss 五参变体
- 模组端自动隔离（③）：Forge/NeoForge/Fabric/vanilla 四处 gameDir=versions/<id>/game
- 文字重叠自适应（④）：ame232 swizzle 镜像 UILabel 渲染取代九轮手动几何镜像（223 行→镜像块，分歧族构造性消除）
- 退出游戏三级解析（⑧）+ 齿轮球两路径补 raise（⑦a）；Vulkan 崩溃与透明边待用户日志/截图（⑤⑦b）
- 门禁四道全 PASS；推送 20fd141 → run 38064942317 一轮终绿；worklog 242/242-ci 双闭环

Stage Summary:
- 新 IPA 就绪：玻璃档全菜单魔改悬浮弹窗化、原生档名实相符、新装版本自动隔离、文字重叠自适应根治
- 下一步 = 用户装机验证；待输入 = 透明边截图 + Vulkan 崩溃 latestlog

---
Task ID: 6
Agent: main (Super Z)
Task: Task 243——用户装机三反馈（IMG_0376 文字黑条 / IMG_0378 游戏内菜单黑面板 / IMG_0377 把手白边）

Work Log:
- 读本地/仓库 worklog 尾部 + Task 242 提交链，还原分轨呈现与描边镜像现状
- 三截图取证定位：①黑条 = Task242 描边 swizzle 的 renderInContext 渲染出口在真机异常（IMG_0373 无 vs IMG_0376 有，唯一变量锁定）②游戏内黑面板 = UIGlassEffect 在 Metal 帧上不合成（Task228/230/236 三轮装机实锤的已知平台行为）③把手白框 = LGC 组合玻璃的 _LGCSheenView 高光在磨砂失效时恒裸露
- 修复：①描边镜像保留属性镜像（自适应核心），渲染出口改直调镜像 label 的 drawTextInRect:（类目自声明先例），绕开 layer display 嵌套 ②游戏内主菜单 showMenu 前 keyWindow 0.18x 抓帧自绘磨砂（先抓后显防自噬）+ AmeFloatingMenu 弹层同机制（present 前抓帧传参）③游戏内常驻件（齿轮球/统计条/caption）跳过 LGC 玻璃改纯深胶囊 + 0.5pt/0.20 减淡细边
- CI 疑云虚惊排除：疑似 "ost presentViewController" 编译炸弹实为 bash/python3 显示层吞字（git blob + GitHub API + Read 工具 + CI 日志四重验证），教训升级入库
- 门禁四道全 PASS；提交 3e83110 + worklog 2bc0f46 推送 main；CI 轮询中

Stage Summary:
- Task 243 全链提交待 CI 出包：黑条根治 / 游戏内快照磨砂（主菜单+弹层双覆盖）/ 把手胶囊化
- 待分诊：抽屉内"大小"标签确切来源（四候选全排除，等装机日志）；Vulkan 崩溃待 latestlog

---
Task ID: 7
Agent: main (Super Z)
Task: Task 243 CI 闭环

Work Log:
- run 38070015169（2bc0f46）failure：AmeFloatingMenu.m:775 类方法内 self.view 编译雷（Class 指针 member reference，双报同源）
- r1 8915146：直传 presenter.view（函数内 window==nil 护栏天然兜底），注释入档；run 38071105322 一轮终绿
- 门禁盲区记录：task240/158 语法/平衡门不查 Class/实例语义混淆，此类雷只能 CI 实证
- 仓库 worklog 243/243-ci 双条目闭环（6a484c0 推送）

Stage Summary:
- Task 243 交付：黑条根治（renderInContext→drawTextInRect 直调）/ 游戏内快照自绘磨砂（主菜单+弹层）/ 常驻件胶囊化，新 IPA 待装机验证
- 待用户：装机截图验证三修复 + "大小"标签错位的 [GameMenu] 日志 + Vulkan latestlog

---
Task ID: 8
Agent: main (Super Z)
Task: Task 244——用户装机反馈（IMG_0379）：液态玻璃改回来/纯黑弹窗/Vulkan 光影闪退

Work Log:
- IMG_0379 取证：主页"选择版本"弹窗纯黑（AmeFloatingMenu 玻璃档面板），设备已升 iPadOS 27.0.1；时间线复盘锁定 UIGlassEffect 本进程从未渲染成功（Task237 时代 SystemMaterial = 用户夸"非常好"；Task239 换玻璃后连报三轮毛玻璃没生效）
- 玻璃根治：LGCNativeGlassEffect 默认退役（AME239_FORCE_SYSTEM_GLASS=1 诊断回取）；AmeFloatingMenu + 游戏内菜单双层改"快照即成品磨砂"——全黑帧护栏（1x1 降采样判黑）+ tint 上移至快照之上（快照不透明，底色压暗结构性失效）+ 材质层快照在场时隐藏 + showMenu 抓帧点联动与原生档幂等清理
- Vulkan：用户上传 latestlog（ba93107）取证成功——VulkanMod 0.6.8+26.1.2 + etallum 光影（无 Iris），进世界渲染正常（fps=60 hotbar 已画）后 ~19s SIGSEGV at _platform_memmove（liblwjgl 帧）= mod/MoltenVK 驱动层崩溃，启动器不可修；新增启动前 [Task244] Vulkan forensics 面包屑（VulkanMod×Iris 共存嗅探）
- 门禁三道 PASS；rebase 网页上传 ba93107 后推送 6719a29；CI 38074831106 轮询中

Stage Summary:
- 装机预期：全部玻璃档弹窗 = 模糊真实背景 + 深色可读 tint + 圆角细边（"选择版本"不再是纯黑）；原生档零回归
- Vulkan 用户指引：VulkanMod+光影为上游组合脆弱点——建议 VulkanMod 升级最新版或改走 zink 渲染器 + Iris（启动器 zink 路径已带光影崩溃修复族）；崩溃时 hs_err 诊断弹窗 + [Task244] 面包屑可供下轮分诊

---
Task ID: 9
Agent: main (Super Z)
Task: Task 245——IMG_0380 用户定案（"这透视有问题吧"+"选择项就应该使用系统原生的液态玻璃"）：选择菜单回归系统原生液态玻璃 + 磨砂弹窗透视根治

Work Log:
- IMG_0380 取证：账号"选用账号"选择菜单走了魔改磨砂弹窗（Task242 玻璃档全接管遗产），快照底衬透见 App UI 轮廓；用户定调架构：选择项菜单 = 系统原生液态玻璃（IMG_0370），魔改磨砂弹窗专属输入类场景（内存数值输入等）
- 定位两案同源：①弹窗快照 AspectFill 居中裁剪 = 整屏快照中心放大裁切，弹窗背后根本不是该内容 = "假透视"几何错位 + 柔化不足轮廓可辨；②选择菜单误入磨砂面板域 = Task242 分轨未按锚点域区分
- AmeNativeMenu.m 玻璃档按锚点域重新分轨：启动器内选择菜单 → 系统原生液态玻璃直出（Task241 三级降级链复活：presentMenu 探测 → _presentMenuAtLocation: → 字典 actionSheet 兜底；玻璃档兜底由磨砂面板接管）；Metal 游戏面（SurfaceViewController 层级/gameMenuOverlay responder 链判定）保持磨砂面板（系统上下文菜单磨砂在 Metal 不合成，Task228/230/236 同族）；delegate（UIContextMenuInteractionDelegate）与 associated keys 自 955027d 复活
- AmeFloatingMenu.m 快照磨砂改【窗口对位真透视】：快照 1:1 铺进面板圆角裁剪容器（帧 = 窗口矩形映射面板坐标，OverFullScreen 下 self.view 即窗口），tint 收编进容器，二次柔化（Ame245SoftenSnapshot 半分辨率重渲染）；ame237_layout 帧刷新（键盘避让/旋转/首布局修正，先于 CA 提交无闪烁）
- 内存数值输入（ProfileSettings showMemoryAllocator = alert+textField）经中央路由 hook 走磨砂面板 = 用户要的归属，自动获得窗口对位真透视修复
- 门禁四道全 PASS；NO-IMPORT 假阳性（注释组件名尾随空格触发 grep，Task241 同族）改写措辞消除
- 推送 55a2413 → run 38077518374 轮询中（poll_ci_task245.sh 后台）

Stage Summary:
- 架构定稿：玻璃档 = 启动器内选择菜单系统原生液态玻璃（IMG_0370）+ 输入类弹窗/Metal 游戏面菜单魔改磨砂（窗口对位真透视）；原生档零回归（旧版系统弹窗）
- 待用户装机验证：①账号 ⋯/选择版本/下载筛选等选择菜单 = 系统玻璃菜单 ②内存数值输入等弹窗 = 背景真实折射磨砂（非透视见底/非纯黑）③游戏内分辨率弹窗同款
- 【闭环补记】run 38077518374 一轮终绿；repo worklog 245/245-ci 双条目已推送（61c44d3）；新 IPA 就绪待装机验证

---
Task ID: 246
Agent: main (Super Z)
Task: 用户指令四件套——伪液态玻璃风格档 / 欢迎向导风格选择页+真实预览 / 动态磨砂背景根治 / MoltenVK 更新

Work Log:
- repo-prisma 全量实施（详见仓库 worklog.md Task 246 条目）：LiquidGlassCompat pseudo_glass 枚举+解析；AmeNativeMenu 伪玻璃档路由；AmeFloatingMenu 8Hz presenter-view 重抓+键盘帧跟踪；WelcomeViewController 新步骤5（风格卡片+预览按钮）；设置页四档；4 lproj +9 键；MoltenVK 1.4.3（main@2c28e0c8 CI artifact）替换+注释同步
- 门禁：task240/139/158/175/211+task191 全 PASS；verify_task219 重锚后 81/81；N4/verify_task237 为既有损坏（stash 复核）

Stage Summary:
- Task 246 代码全量完成，待提交推送盯 CI；装机验证锚点：欢迎页风格选择+预览三态、伪玻璃档磨砂全接管、动态背景跟随、Vulkan 光影崩溃点是否消失
- 【闭环补记】run 38080642144（8105017）一轮终绿 + worklog 文档轮 38081916900（289ba13）success；repo worklog 246/246-ci 双条目已推送，新 IPA 就绪待装机验证

---
Task ID: 249
Agent: main (Super Z)
Task: Prisma-Minecraft-iOS-Launcher 阶段10修订版 9 项装机反馈修复（Task 249 全链闭环）

Work Log:
- 取证：解析用户上传的 latestlog.txt/old.txt（bb32e00 构建）——实锤退出路径=游戏内玻璃菜单 ForceClose、MobileGL 输入错位根因=后台旋转推送改写 windowWidth 全局（1814x1262 vs 物理 2360x1640）、Vulkan 会话无 BG-Park 停靠点
- 修复 7 项代码（T1 重宣告时序/T3 OnDrag+回填闸/T4 Metal 停靠点/T5 周期回环扫描/T7 MVC 玻璃补位/T8 关闭动画摘快照/T9 动态键闸），2 项（T2/T6）确认为 Task248 已修面
- 门禁五道全绿 + verify219 重锚 81/81 + i18n 三闸全 PASS；CI r1（MVC 补 objc/runtime.h）→ r2 一轮终绿 run 38115274201

Stage Summary:
- 提交链 3cf1fe9→e6f612a→9c35cd9 已推送；新 IPA 就绪待装机验证（8 条锚点见仓库 worklog Task 249）

---
Task ID: 255
Agent: main (Super Z)
Task: Prisma-Minecraft-iOS-Launcher 阶段11 十五项清单（Task 255 全链）：gamelog 先行诊断后 15 项（联机根因/输入自动纠正/毛玻璃第二刀/右 Shift/版本+清理/皮肤/渲染器/JVM 预设/控件更新/CI/公告/i18n/品牌）

Work Log:
- gamelog 取证：7bacfd3 装机日志（无切后台样本）+ old.txt 切后台样本（恢复链全开火）+ terracotta 日志（PingHostFail×4）+ 主日志 FromUtf8Error 实锤 → 联机根因 = 启动器 LanPortDetector 合成握手探针打崩本机 Terracotta ScaffoldingServer（字节级吻合）
- 沿用工作区半成品（上会话遗留 558 行）转正并补齐：路径根 POJAV_HOME→POJAV_GAME_DIR 修正 3 处 + ReloadProfileList + 毛玻璃 0.01 跳层分支退役 + JVM 预设消费端四档 + 右 Shift 会话重置三件 + 联机预检 4 peer + 控件自动检查更新全链 + 公告 43→6 + 品牌 22 表/25 日志/UA + CI 合一与缓存 + i18n 缺键清零
- 事故与修复：MultiEdit 原子性异常（部分落盘）逐一验证补齐；批量替换脚本 universal newline 行尾翻转（7 文件 CRLF 还原 + JavaGUI checkout HEAD）；verify_task219 重锚（2810 键/公告 6 条/K4 CRLF 还原）
- 门禁：verify_task255（新 51 断言）51/51 + task240/139/175 全 PASS + task158 16 文件 PASS（sdl3_hook 既有误报 HEAD 对照）+ task248/250/191 全绿 + verify_task219 81/81
- 提交 afcc90e 推送 main；run 38156229988（run#794）轮询中

Stage Summary:
- Task 255 代码全量交付（15/15 项），新 IPA 待 CI 出包后装机验证；锚点见 repo worklog Task 255 Stage Summary 8 条
- 【闭环补记】afcc90e→r1 1a13bd9（消息方括号 ?: 语义雷）→r2 55456d9（block 签名老顺序）→run 38158214004（run#796）一轮终绿 + worklog 文档轮 1766a07 推送；repo worklog 255/255-ci 双条目闭环，新 IPA（220.4MB）就绪待装机验证

---
Task ID: 256
Agent: main (Super Z)
Task: Prisma-Minecraft-iOS-Launcher Task 256 七项清单（gamelog 先行诊断）：联机/清理入口/毛玻璃最低档/渲染器自动选择/CI 速度/i18n/JVM 预设

Work Log:
- gamelog 取证：55456d9 双日志——①1.8.9-forge 会话 MobileGL ftransform 顶点着色器编译崩（自动选择器被 legacy 档位键劫持，kw 链未跑）②26.3 会话 Terracotta init 后 5s（Disconnected 期）探针打崩 ScaffoldingServer → 房主 HostOk 后访客仍 PingHostFail（Task255 会话闸的洞）③IMG_0400 最低模糊白雾 ④verify 审计发现 PLPrefTableViewController 键名派生族（title/detail/confirm/done）30 键全表裸键名
- 七项全修：探针确定性闸（+hasInitializedLibrary 静态标志类方法，9 处闸替换）+ PingHostFail 自动重试 2 次；清理垃圾主页磁贴+扫描类方法化；毛玻璃最低档整层不装+blurUserSet 意图标记（TVC/MVC 快照磨砂与轻 dim 同口径）；≤1.16 未显式选择强制 auto→kw 链；CI VirGL prebuilt 分支+actions/cache（省 ~10min/run）；派生键审计+54 表 2263 键补齐；JVM 预设进版本设置（profile.jvm_preset→ame256_effectiveJvmPreset 单一事实源）
- 事故三件：Edit 工具把 Makefile TAB 整文件展开为空格（checkout+python 字节级 splice 重做，教训：TAB 敏感文件禁用 Edit 工具）；workflow 插入行未继承缩进炸 YAML（重做带缩进+yaml.safe_load 验证）；verify219/255 六+二处锚点顺延重锚 + announcements.json 工作区漂移 checkout 恢复
- 门禁：task139/240 双门+import sweep PASS；task191 54 表 OK；task248 缺键0/硬编码0/动态键0；task250 直显0；verify_task255 51/51；verify_task219 81/81 ALL GREEN
- 提交 e17ea80（代码）+ 3159f0f（worklog）推送 main；CI 轮询中

Stage Summary:
- 七项全链交付待 CI 出包；装机锚点 6 条见仓库 worklog Task 256 条目
- 教训升级：①工具显示层吞字第三例（[message→essage）②Edit 工具 TAB 展开面 ③run-block 插入须继承缩进

---
Task ID: 256-ci
Agent: main (Super Z)
Task: Task 256 CI 闭环（run 799 failure → r1 run 800 一轮终绿）

Work Log:
- run 799 failure：ame256_scanVersionsForCleanup 类方法未在 .h 声明（跨文件 selector 静态盲区，Task255 r1/r2 同族）→ r1 45d83d9 补 VersionManagerViewController.h 声明 → run 800 一轮终绿
- 产物 ipa/tipa 220.5MB + dSYM 6.3MB 全在位；VirGL 缓存首桶落袋（virgl-prebuilt-v1-daa95f3…），后续每 run 预期省 ~10.7min（Mesa 906 目标双遍全量编译跳过）
- worklog 文档轮 0707bd0 推送（run 801 = 缓存命中首个验证轮）

Stage Summary:
- Task 256 七项全闭环：联机双刀/清理磁贴/毛玻璃最低档全透明/渲染器 kw 劫持根修/CI VirGL 缓存/i18n 派生键 54 表清零/JVM 预设实例级——新 IPA 就绪待装机验证（锚点见仓库 worklog Task 256 条目）

---
Task ID: 256-ci (r2 addendum)
Agent: main (Super Z)
Task: Task 256 CI 收尾——VirGL prebuilt 契约修正（run 801 命中未触发 → r2 726e647 根修）

Work Log:
- run 801 复盘：cache hit 但 dep_virgl 仍全量；staging ls 实锤 libepoxy.dylib 从源码路径不产出（静态链进 libvtestserver）→ 三件契约恒假
- r2 726e647：契约两件套（Makefile prebuilt 分支 + workflow staging 同步；python 字节级编辑保 TAB/CRLF）→ run 802 绿 + 新桶 85d96afb 落袋（19MB+2.1MB=分支校验集）
- worklog 文档轮 da21223 推送；CI 提速自 run 803 生效（~9.4min/run）

Stage Summary:
- Task 256 七项全闭环：新 IPA（220.5MB）就绪待装机验证；锚点见仓库 worklog Task 256 条目 Stage Summary 6 条

---
Task ID: 257
Agent: main (Super Z)
Task: Prisma-Minecraft-iOS-Launcher Task 257 四项清单（gamelog 先行诊断）：联机自动重试根修 / 渲染器 FSR 联动误入根修 / CI 提速第二轮 / i18n 中文补全

Work Log:
- gamelog 取证（da21223 双日志）：①联机——访客 GuestStarting 后 ~15s Cannot find scaffolding server→PingHostFail；Task256 重试 firing 后 26ms keeping-alive 翻转 = Exception 态 set_guesting 被拒返回 0，自动重试从未生效 ②渲染器——1.8.9 会话 kw 链已生效但 SurfaceVC Task83 FSR 联动在修正前读 ame_effective_renderer()=libMobileGL → mgFsrScale=2.00 缩窗先行锁死 → kw 会话半分辨率无升采样
- 四项修复：TerracottaManager 重试链 setWaiting 复位+1.5s 沉降再重入（FCL/PCL2CE 语义，giveup 改 i18n_str_989）+ SurfaceVC 镜像 Task256 ≤1.16 门（javaVersion 同源，非显式→FSR 联动按 kw 对待全分辨率）+ CI 第二轮（JRE 四目录缓存/第二遍去 dsymutil/submodule 浅克隆并行）+ 中文三表 36 键英文残留清零（新工具 task257_zh_l10n_sweep.py + 译表 108 处落盘）
- 事故两件：MultiEdit 在 CRLF workflow 插 22 个纯 LF 行（K4 破防→字节级归一复绿）；sweep 首版 fix 自斥 bug（0 重写→重构候选集）
- 门禁：task139/240+import PASS；task191 OK；task248 缺键0/硬编码0/动态键0；task250 裸键名0；verify255 51/51；verify219 81/81 ALL GREEN；yaml 校验 26 steps
- 提交 25385c1（代码）+ 14ad343（worklog）推送 main；run 804 一轮终绿 18.6min（JRE 首桶落袋，提速自 run 805 生效）；产物 ipa/tipa 220.5MB+dSYM 在位

Stage Summary:
- Task 257 四项全闭环；装机锚点：①PingHostFail 后见 "Task257: retry N re-entered guest flow" ②1.8.9 见 "Task257: legacy MC ... FSR linkage disengaged"+全分辨率 ③run 805 起 JRE 缓存命中 ④中文 36 处不再英文

---
Task ID: 262
Agent: main (Super Z)
Task: Prisma-Minecraft-iOS-Launcher Task 262 三项（装机日志先行诊断）：⑧大型整合包无输出第三轮复现——探针盲区结构性根修 / ②右Shift摁下去高亮双根因 / TouchCancel 连坐；v6.5.0 静默替换第四轮

Work Log:
- 发现 Task 261 已在另一会话全链闭环（affe8d3 r1→0c5a6dc r2→1087faa 收尾，远端领先 14 提交），pull 同步；用户设备实装 0c5a6dc（v6.5.0）
- 判读用户上传 latestlog.txt（Cobblemon 1.8.2/fabric 1.21.1 第三次复现）：t+9.074s 起 GC/safepoint 双零=全线程静止非慢加载；卡点 mod init 期窗口前；Task261 自诊断探针全程零输出
- 探针盲区根修（Tools.java）：fabric 在 Minecraft 构造器 super("Render thread") 即改名→相位1的15s首醒静默转相位2（再睡8s）→首栈最早 t+23s 恒被手杀抢跑；根修=相位1前3样本 6s 无条件落栈+相位2首样本立即落栈
- Cobblemon showdown 联网取证：镜像源码逐行吻合（createContext:110 首eval触发 CommonJS cwd 校验，<user.dir>/showdown 不存在→toRealPath NoSuchFile→报错）；openHAB#11616/JavaUWP mixin 三方互证；因果关系未证实不盲修，待看门狗 t+6s 双栈定音
- ②双根因修复（SurfaceViewController.m）：右SHIFT主按钮 bgColor alpha≈0.055 幽灵键使 ame261 高亮不可见→alpha 下限 0.30 对齐持续奔跑观感；仅锁存后着色→mod 键 DOWN 即高亮（UP 三路径天然对称还原）
- TouchCancel 连坐：游戏按钮未挂 UIControlEventTouchCancel→触摸被抢修饰键永久按住（潜行卡死）+高亮卡色；补挂 cancel→up_outside 同路径（长按释放分支补发 UP 清锁存还原）
- 事故：工具显示层吞字第四例（[menuButton 显示为 enuButton，od -c 字节级交叉验证排除文件损坏，历史教训同款）
- 门禁：task139/240 all balanced；task191 54 表 2907 OK；task248/250 零；verify219 重锚后 81/81（唯一键 2873 实测+K1 包名跟随 Task259 迁移）；verify255 51/51
- 提交 7783679 推送 main；CI run 38323985746（run#820）轮询中

Stage Summary:
- Task 262 三项代码全量交付：①⑧下轮复现 t+6s/t+12s 必达主线程 24 帧栈（直接定位卡死 mod）②右SHIFT 按住/锁存均可见高亮（alpha 0.30）③触摸被抢不再潜行卡死；待 CI 绿→v6.5.0 资产静默替换第四轮→装机验证

- 【闭环补记】CI run 38323985746（run#820）一轮终绿；v6.5.0 资产静默替换第四轮完成（ipa/tipa 同名保链 updated_at=2026-10-13T00:08，构建=7783679）；repo worklog f13bfe6 推送闭环
- 装机验证锚点：①整合包再复现→日志 [LaunchWatchdog] entrypoint-phase sample #1（t+6s 必达主线程 24 帧栈，直接定位卡死 mod 与调用点）②游戏内轻点/按住右SHIFT→按钮 tint 高亮（alpha 0.30 可见级），锁存态持续高亮再点还原 ③触摸被系统手势抢走不再潜行卡死

---
Task ID: 306
Agent: main (Super Z)
Task: Prisma-Minecraft-iOS-Launcher Task 306 双线根修：SideStore 直装内置 JIT 误导弹窗 / LC 容器游戏 Mixin 阶段闪退死无对证（SIGKILL 感知）

Work Log:
- pull 对齐 origin/main（f13bfe6 → a479ffb6，Task 303/304/305 全链落地；设备构建 = 579453c8 = Task305，tag v6.5.5）
- 判读用户 latestlog.txt（LC guest 会话）：JIT 自动轨全链成功（Task134 enabler=auto builtin=0 → Task176 openURL stikjit://=1 → Task181 3.6s satisfied traced=1 exn=1 → JIT26 64MB mapping 到手）——JIT 主链路已修通，用户"内置 JIT 无法使用"实为 SideStore 直装场景手点 builtin 菜单触发 direct-spawn 必死轨
- IMG_0449 定性：直装 bundle 路径 /var/containers/Bundle/Application/.../App.app/（非 LC），posix_spawn rc=1 errno=2，弹窗误导性建议 re-sign PlugIns/ ——与 Task43 shaderc 真机恒 EPERM 同源：无 no-sandbox/dynamic-codesigning entitlement 时沙盒/AMFI 拒绝 spawn 行为本身，重签无解
- 线①：StikDebugViewController 双 gate（ame294_builtinTrackAvailable/ame294_enableBuiltinJITWithCompletion）加 ame306_spawnDerivable（SecTask SPI entitlement 存在性判定），判 NO 直接回 ame306.jit.spawn_denied 如实报错；auto 模式直通 stikjit:// 链路无损
- 线②：SIGKILL 级闪退感知——main_hook ame306 三函数（marker 立桩/钩子清除/残留感知铸 sigkill_like 报告），begin 挂 JavaLauncher JLI_Launch 前，end 挂 hooked_exit 两分支+hooked_abort JVM fatal 直通，consume 挂 SceneDelegate 冷启动补弹前；ame273 报告在则不叠加（防双弹）
- 线③：PrismaJITCoordinator.swift direct-spawn 兜底文案中性化（摘 re-sign 误导）
- 线④：task306_i18n.py——ame306.jit.spawn_denied 54 表注册；根修 task302 ALIAS 缺 zh-CN 映射的历史 bug（zh-CN 表 ame302.jit.lc_guest 英文残留→中文实译）
- 门禁：task139/task240 all balanced；task248 缺键0硬编码0；task250 动态键齐备；verify191 2 fail 经 stash 对比证实为历史存量
- 提交 4043e406 推送 main，CI 轮询中

Stage Summary:
- 直装/LC 双场景内置 JIT 均不再空跑必死 spawn：LC→ame302 如实报错，直装无 entitlement→ame306 如实报错，TrollStore/越狱照常放行
- SIGKILL 级闪退不再死无对证：Mixin 阶段闪退后，下次冷启动/下次点启动均会呈现"进程异常终止（SIGKILL 级）"分析弹窗（含成因三候选与处置指引）——闪退定位数据闭环补全
- 装机验证锚点：①SideStore 直装点"内置 JIT"→ 见 ame306 如实提示（无 re-sign 字样）②LC 点启动→ stikjit:// 自动跳转照旧 ③若再闪退→ 冷启动 2.5s 后玻璃弹窗给出上次会话死亡分析（SIGKILL 疑报或 ame273 正式报告）

---
Task ID: 306-r2
Agent: main (Super Z)
Task: Task306 装机验证判读（862ea2c latestlog）：Task273 呈现链实证工作 / Task306 marker 上桩 / 闪退点推进定性 / StikDebug vs 内置 JIT 原理答疑

Work Log:
- CI 确认：862ea2c completed success（4043e40 cancelled 为同批抢占，最终 HEAD 绿）；设备日志 Commit 862ea2c = Task306 已装机
- 装机实证一：Task273 崩溃报告呈现链工作——"上次游戏异常退出"玻璃弹窗弹出（actions=3），category=JVM/原生层致命错误 exit=6（SIGABRT=JVM fatal 路径）details=18，consumed+archived；上轮"闪退零分析"定性修正：上轮非 SIGKILL，是 JVM fatal 且 Task305 直通前落盘的报告成功送达呈现层
- 装机实证二：[Ame306] game session marker armed 出现在 JLI_Launch 前——marker 生命周期机制上桩生效
- 装机实证三：JIT 自动轨照常（stikjit://=1 → traced=1 → JIT26 mapping 0x159438000）；Task304 改名弹窗不再出现；启动校验 verify-and-continue
- 闪退点推进定性：上上轮 Mixin subsystem 后（GC(5) 1.557s）→ 本轮 Main Arguments Transformer 完成+Metallum classes define 进 MC loader（GC(11) 2.131s 截断）——ame298 GOT 修复后逐轮加深，符合"逐雷排查"模式；最终雷点待弹窗 Problematic frame 锚点定位
- 本轮会话日志无 Task306 spawn gate/Task302 gate 触发行——用户本轮未点内置 JIT 菜单，直接点启动
- 无代码变更轮（判读+答疑）；向用户交付 StikDebug 能拿 JIT 权限的原理答疑与取证指引

Stage Summary:
- 崩溃分析画面从"缺失"转为"实证工作"；下一步定位闪退根因只差用户下次闪退后重启启动器截图"上次游戏异常退出"弹窗（headline 含 Problematic frame）
- 内置 JIT 结论定案：非越狱 SideStore/LC 装机结构性不可用（spawn 被沙盒拒+EX 轨被 installd 拒），StikDebug 深链为唯一 JIT 轨且已全自动工作

---
Task ID: 307
Agent: main (Super Z)
Task: StikDebug 源码研究（用户指令 git clone 研读）+ JVM 崩溃四件套定性（hs_err_pid47069/latestlog/fatal_trace/ame273 报告）→ MoltenVK 闪退根修 + 崩溃弹窗一键自愈

Work Log:
- git fetch 对齐：本地 HEAD = origin/main = 862ea2c（恰为设备构建 commit，Task306 已装机，无落后）
- StikDebug 研究（clone StikDebug/StikDebug @ 17b1e1d，Swift+idevice FFI）：①原理与内置 JIT 完全异构——自身 entitlements 仅普通 app-sandbox，无任何 spawn/task 权限；JIT 靠"让设备自己的平台服务干活"：pairing file（SideStore 安装时生成）→ tunnel_create_rppairing 连 10.7.0.1:49152（loopback VPN 下设备自身 remotepairing）→ RSD 隧道 process_control_launch_app（设备侧 launchd/CoreDevice 拉起 app）→ debug_proxy_connect_rsd 连 com.apple.debugserver（平台二进制，有 get-task-allow 特权）→ vAttach 附加②深链协议 stikjit://enable-jit?bundle-id=&pid=&script-data=&script-name=（HomeView.handleExternalURL，四参数全兼容；confirmExternalJITRequests 控确认框）③JIT26 协议脚本 universal.js：拦截 brk #0xf00d（x16=0 Detach/1 PrepareRegion/2 NewBreakpoints），_M<len>,rx 分配 RX 内存 + prepare_memory_region 建 RW 镜像 + P0= 写回——与我方 JIT26SendJITScript/JIT26 mapping 完全互为对端；maciOS.js 为 legacy brk 0x69 三断点变体（MeloNX）④LC 专项告示：StikDebug 明确提示"应在 LC 设置选 StikDebug 为 JIT 助手（Run with JIT），app 正常打开会自动跳回"——我们 stikjit:// 自动深链即此路径，已跑通（traced=1）。结论：内置 JIT 在无越狱装机结构性不可能（spawn 权限在平台服务手里），Task306 门+自动深链为终态架构，深链参数无需改动
- 崩溃四件套定性：hs_err_pid47069 = 唯一独立雷点——JVM 启动后 5.749s 于 MC GlDevice 创建（GlBackend.createDevice ← Minecraft.<init>，Render thread）SIGSEGV SEGV_ACCERR @null+0x40（ldr w9,[x0+0x40]，x0=0），problematic frame libMoltenVK.dylib vkSetWorkgroupSizeMVK+0xbc（大偏移符号错位，x20 指向 SPIRVToMSLConverter::convert 区），原生栈 pojavMakeCurrent→gl_make_current→libMobileGL eglMakeCurrent→MoltenVK 首次管线初始化；fatal_trace 其余条目均为退出路径伴随（Task251 看门狗/Task48 强关/VM_Exit os::exit(1)/libjvm VMError 直通），非独立雷点；JIT 主链本轮实证健康（stikjit://=1 → traced=1 exn=1 → JIT26 mapping 0x159438000 → JVM 进到 MC 初始化）——"游戏闪退"本轮定性 = 渲染层 MoltenVK 雷，非 JIT 雷
- 根因链：MC 26.1.2（prefer_vulkan 无 VulkanMod → GlBackend GL 路径）→ LWJGL→MobileGlues(libMobileGL, backend=DirectVulkan，mobileglues.mobilegl_backend 默认 1)→ GL→Vulkan→MoltenVK→Metal，首次 GL 上下文 make-current 期 MoltenVK 管线初始化空指针崩溃（本机/LC guest 兼容性雷）；唯一绕开 MoltenVK 的 MobileGL 档 = DirectGLES（Espryt/ANGLE 翻译，Task156 multidraw 已有 drawelements 兜底）；Mithril 亦 Vulkan 后端（glGetString "3.3.0 Mithril-Wrapper (Vulkan 1.2 / MoltenVK)"）切它无效
- 修复三件：①main_hook ame273 生成端——JVM fatal 且 "libMoltenVK.dylib+"（库名+偏移强特征，避开命令行 libname=MoltenVK 弱引用误报）与 libMobileGL.dylib 同场 → fix 换定向缓解指引（中英双语句单行内嵌，保报告按行解析器安全）②SceneDelegate 呈现端——ame273 弹窗 headline 含 libMoltenVK.dylib 且 getPrefInt(mobileglues.mobilegl_backend)!=2 时追加"一键切换 GLES 后端"动作（写 =2 + ame307_gles_fallback.txt marker 取证，下次启动生效）③i18n task307_i18n.py：ame307.crash.switch_gles 54 表注册（主语言实译+EN 兜底）
- 门禁：task139/task240 all balanced；task248 缺键0硬编码0动态键0；task191 54 表 OK；task307_verify.py 五断言（真实样本命中/命令行弱引用不误报/无 MobileGL 不误报/headline 判据/fix 单行）全 PASS
- 提交 3072dc3f 推送 main；CI run#941 首轮 cancelled 无失败步骤（历史同款抢占形态，run#939 同款）→ API rerun 201，后台轮询中

Stage Summary:
- 闪退根因从"死无对证"到"定点定性"：MoltenVK（MobileGL Vulkan 后端）着色器管线初始化崩溃，与 JIT 无关；用户下次遇同类崩溃将看到定向 fix 文案 + "一键切换 GLES 后端"自愈按钮
- StikDebug 机制定案入档：pairing file + loopback VPN + 设备侧 debugserver 附加；内置 JIT 非越狱结构性不可用为终局结论（不再投入）
- 待 CI 绿 → artifact 出包 → v6.5.5 资产静默替换 → 装机验证锚点：①再遇 MoltenVK 崩溃 → 弹窗见"一键切换 GLES 后端"按钮，点按后下次启动 MOBILEGL_BACKEND_TYPE=DirectGLES ②或用户手动设置-视频-渲染器-MobileGlues 后端切 GLES ③日志锚点 [Ame307] GLES fallback engaged / ame307_gles_fallback.txt

---
Task ID: 307-ci
Agent: main (Super Z)
Task: Task307 CI 闭环 + v6.5.5 资产静默替换

Work Log:
- run#941（3072dc3f）首轮 cancelled 无失败步骤（同批抢占形态，run#939 同款先例）→ API rerun 201 → 一轮终绿 completed success
- artifact 三件落袋（ipa 221.7MB / tipa 221.7MB / dSYM 6.5MB）；下载解压出 com.prisma-devs.prisma-6.5.5-ios.ipa + -trollstore.tipa（构建=3072dc3f）
- v6.5.5 资产静默替换第八轮：DELETE 旧 asset 656802672/656803606（updated=2026-10-19T16:35，上一轮 862ea2c 构建）均 204 → uploads POST 双 201，同名保链 updated_at=2026-10-19T18:35 前后，构建=3072dc3f
- worklog 文档轮待下批推送（本条目即取证）

Stage Summary:
- Task307 全链闭环：MoltenVK 定性 + 一键自愈修复已进 v6.5.5 资产；装机验证锚点见 Task307 条目 Stage Summary
