#!/usr/bin/env python3
# Task 268 r2 综合批：子代理五路侦察修复 + touch 协议恢复 bug 根修 + v6.5.0 交付回退
# 全部字节级 + 幂等 + 计数断言。
import re, sys

FAILURES = []

def patch(path, pattern, repl, label, expect=1, marker=None, flags=0):
    try:
        data = open(path, "rb").read().decode("utf-8")
    except FileNotFoundError:
        FAILURES.append(f"{label}: file not found {path}")
        return
    if marker and marker in data:
        print(f"SKIP {label}")
        return
    new, n = re.subn(pattern, repl, data, count=expect, flags=flags)
    if n != expect:
        FAILURES.append(f"{label}: {n}/{expect} in {path}")
        return
    open(path, "wb").write(new.encode("utf-8"))
    print(f"OK {label} x{n}")

# ============ ① ios_uikit_bridge.m：touch 协议恢复 bug 根修 ============
BR = "Natives/ios_uikit_bridge.m"
patch(BR, r'(#import "PLProfiles\.h"\n)', r'\1#import "ModService.h"   // Task268：profile 生效 mods 目录实况核对\n',
      "br-import")

BR_NEW = '''static void ame172_applyProfileTouchController(void) {
    @autoreleasepool {
        NSString *profName = PLProfiles.current.selectedProfileName;
        NSDictionary *prof = profName ? PLProfiles.current.profiles[profName] : nil;
        id rawKey = [prof isKindOfClass:NSDictionary.class] ? prof[@"touchController"] : nil;
        BOOL profOn = [rawKey boolValue];
        // ★ Task268（用户报"装 touch 模组后关不掉 touch 协议/屏蔽控件，关了开游戏又恢复"）：
        //   旧语义两个洞——a) profile 键 YES 但 mods 已无 TouchController jar（模组管理
        //   删了 mod，键残留）时只认键不看实况，启动照样自动配置 UDP+屏蔽控件；
        //   b) 版本设置"关闭"= 删键（无键），启动链对无键不碰全局——全局残留 ON =
        //   关闭形同虚设。修法：YES 键先核对 mods 实况（jar 不在=本会话禁用）；
        //   显式 NO 键（Task268 保存语义）= 本会话禁用；无键维持"不碰全局"。
        BOOL profExplicitOff = [rawKey isKindOfClass:NSNumber.class] && !profOn;
        if (profOn) {
            NSString *modsFolder = [[ModService sharedService] ame264_effectiveModsFolderForProfile:profName];
            BOOL jarPresent = NO;
            if (modsFolder.length > 0) {
                NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:modsFolder error:nil];
                for (NSString *f in files) {
                    if ([f.pathExtension caseInsensitiveCompare:@"jar"] == NSOrderedSame &&
                        [f localizedCaseInsensitiveContainsString:@"touch"]) {
                        jarPresent = YES;
                        break;
                    }
                }
            }
            if (!jarPresent) {
                NSLog(@"[TouchController] Task268 profile '%@' flag=YES but no TouchController jar in mods -- treating as off for this launch", profName);
                setPrefBool(@"control.mod_touch_enable", NO);
                setPrefBool(@"control.mod_touch_hide_controls", NO);
                return;
            }
            if (getPrefBool(@"control.mod_touch_user_off")) {
                NSLog(@"[TouchController] Task172 profile '%@' auto-config SKIPPED (user turned TouchController off globally -- not re-enabling)",
                      profName);
                return;
            }
            setPrefBool(@"control.mod_touch_enable", YES);
            setPrefObject(@"control.mod_touch_mode", @1);  // UDP 协议
            setPrefBool(@"control.mod_touch_hide_controls", YES);
            NSLog(@"[TouchController] Task172 profile auto-config applied for '%@' (enable=1 mode=UDP hideControls=1)",
                  profName);
        } else if (profExplicitOff) {
            // Task268：显式关闭 = 本会话禁用（按当前 profile 每次启动重落，跨版本
            // 不漂移：YES profile 启动会重走上方自动配置）。
            setPrefBool(@"control.mod_touch_enable", NO);
            setPrefBool(@"control.mod_touch_hide_controls", NO);
            NSLog(@"[TouchController] Task268 profile '%@' explicitly disabled -- touch protocol off for this launch", profName);
        } else {
            NSLog(@"[TouchController] Task172 profile '%@' TouchController off -- global settings untouched",
                  profName);
        }
    }
}

void UIKit_launchMinecraftSurfaceVC'''
patch(BR,
    r"static void ame172_applyProfileTouchController\(void\) \{.*?\n\}\n\nvoid UIKit_launchMinecraftSurfaceVC",
    lambda m: BR_NEW,
    "br-touch-rework", marker="Task268 profile", flags=re.S)

# ============ ② ProfileSettingsViewController.m：显式 NO + 管理手势 ============
PS = "Natives/ProfileSettingsViewController.m"
patch(PS, r'(#import "ModpackExportService\.h"[^\n]*\n)',
      r'\1#import "ModService.h"          // Task268：TouchController 卸载走生效 mods 目录\n',
      "ps-import")

patch(PS,
    r"""    // Task172：版本级 TouchController——开启落 YES，关闭删键（无键 = 关闭，\n    // 启动链 ame172_applyProfileTouchController 同口径；关闭不碰全局设置）\n    if \(self\.touchControllerEnabled\) \{\n        existing\[@"touchController"\] = @YES;\n    \} else \{\n        \[existing removeObjectForKey:@"touchController"\];\n    \}""",
    """    // Task172：版本级 TouchController——开启落 YES。
    // ★ Task268：关闭改写显式 @NO（原"删键"使显式关与从未配置不可分，启动链
    //   对无键不碰全局——全局残留 ON = 用户感知"关了开游戏又恢复"）。启动链
    //   ame172_applyProfileTouchController 对显式 NO 落本会话禁用（同口径）。
    existing[@"touchController"] = self.touchControllerEnabled ? @YES : @NO;""",
    "ps-save-explicit-no", marker='existing[@"touchController"] = self.touchControllerEnabled ? @YES : @NO;')

PS_ROUTER = '''- (void)installTouchControllerStandalone {
    // ★ Task268：已安装态（profile 键 YES）先给管理手势——旧版行点击只会重复
    //   走安装，装完没有任何关闭入口（模组管理删 jar 也关不掉：键残留 YES =
    //   启动链照样自动配置 UDP+屏蔽控件）。
    if (self.profile[@"touchController"] && [self.profile[@"touchController"] boolValue]) {
        UIAlertController *ame268_manage = [UIAlertController alertControllerWithTitle:@"TouchController"
                                                                               message:nil
                                                                        preferredStyle:UIAlertControllerStyleAlert];
        [ame268_manage addAction:[UIAlertAction actionWithTitle:localize(@"component.touch.uninstall_disable", NULL)
                                                          style:UIAlertActionStyleDestructive
                                                        handler:^(UIAlertAction *action) {
            [self ame268_uninstallTouchController];
        }]];
        [ame268_manage addAction:[UIAlertAction actionWithTitle:localize(@"component.touch.reinstall", NULL)
                                                          style:UIAlertActionStyleDefault
                                                        handler:^(UIAlertAction *action) {
            [self ame268_continueInstallTouchController];
        }]];
        [ame268_manage addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:ame268_manage animated:YES completion:nil];
        return;
    }
    [self ame268_continueInstallTouchController];
}

- (void)ame268_continueInstallTouchController {'''
patch(PS,
    r"- \(void\)installTouchControllerStandalone \{\n",
    lambda m: PS_ROUTER + "\n",
    "ps-router", marker="ame268_continueInstallTouchController")

PS_UNINSTALL = '''
/// Task268：卸载 TouchController 模组 jar + profile 键显式 NO + 刷新。
/// 关闭后下次启动 ame172_applyProfileTouchController 走显式 NO 分支 =
/// 本会话无 touch 协议、控件不再屏蔽（用户实测 bug 的关闭入口）。
- (void)ame268_uninstallTouchController {
    NSString *ame268_prof = self.originalName ?: self.profile[@"name"];
    NSString *modsFolder = ame268_prof ? [[ModService sharedService] ame264_effectiveModsFolderForProfile:ame268_prof] : nil;
    NSInteger removed = 0;
    if (modsFolder.length > 0) {
        NSFileManager *ame268_fm = [NSFileManager defaultManager];
        for (NSString *f in [ame268_fm contentsOfDirectoryAtPath:modsFolder error:nil]) {
            if ([f.pathExtension caseInsensitiveCompare:@"jar"] == NSOrderedSame &&
                [f localizedCaseInsensitiveContainsString:@"touch"]) {
                if ([ame268_fm removeItemAtPath:[modsFolder stringByAppendingPathComponent:f] error:nil]) removed++;
            }
        }
    }
    self.touchControllerEnabled = NO;
    [self saveSettings]; // Task268：显式 @NO 语义（ame268 保存口径）
    NSLog(@"[ProfileSettings] Task268: TouchController uninstalled (%ld jar(s)) + profile key=NO for '%@'",
          (long)removed, ame268_prof);
    [self reloadAllTableViews];
}

- (void)installTouchControllerStandalone {'''
patch(PS,
    r"- \(void\)installTouchControllerStandalone \{\n    if \(!\[self isFabricProfile\]\) \{",
    lambda m: PS_UNINSTALL.replace("- (void)installTouchControllerStandalone {", "") + "- (void)installTouchControllerStandalone {\n    if (![self isFabricProfile]) {",
    "ps-uninstall", marker="ame268_uninstallTouchController")

# ============ ③ ModService.m：重试链 + 落点记录文件名 + 取消阶段态 ============
MS = "Natives/ModService.m"
patch(MS,
    r"""    DownloadTaskItem \*ame267_item = self\.downloadTaskItems\[taskId\];\n    \[self cleanupPLDownloadStateForTaskId:taskId\];\n    \[self\.downloadStateLock unlock\];""",
    """    DownloadTaskItem *ame267_item = self.downloadTaskItems[taskId];
    // ★ Task268（scan-d #1）：失败/取消保留 request+taskItem——retryHandler
    //   →restartPLDownloadForTaskId 靠 downloadRequests 命中，旧版一律清空
    //   = "重试"恒 nil → 任务永久卡"等待中"。成功路径才全量清理。
    if (success) {
        [self cleanupPLDownloadStateForTaskId:taskId];
    } else {
        [self.downloadOperations removeObjectForKey:taskId];
        [self.downloadGenerations removeObjectForKey:taskId];
        [self.downloadAccumulatedBytes removeObjectForKey:taskId];
        [self.downloadTotalBytes removeObjectForKey:taskId];
        [self.downloadLastSpeeds removeObjectForKey:taskId];
        [self.downloadProgressHandlers removeObjectForKey:taskId];
        [self.downloadCompletionHandlers removeObjectForKey:taskId];
    }
    [self.downloadStateLock unlock];""",
    "ms-retry-chain", marker="scan-d #1")

patch(MS,
    r"file:\(ame267_item\.displayName\.length > 0 \? ame267_item\.displayName : ame267_item\.resourceName\)\];",
    "file:(ame267_item.resourceName.length > 0 ? ame267_item.resourceName : ame267_item.displayName)]; // Task268：记实际落盘文件名（scan-d #7）",
    "ms-record-filename")

patch(MS,
    r"""    \} else if \(\[error\.domain isEqualToString:NSURLErrorDomain\] && error\.code == NSURLErrorCancelled\) \{\n        // 用户取消（DownloadTaskManager 已置 Cancelled，这里幂等对齐）\n        \[manager setTaskWithId:taskId state:DownloadTaskStateCancelled\];""",
    """    } else if ([error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled) {
        // 用户取消（DownloadTaskManager 已置 Cancelled，这里幂等对齐）
        // ★ Task268（scan-d #8）：阶段行同步置 Skipped——旧版停在 Running，
        //   统一进度页显示"进行中"直到页面关闭。
        [manager updateTaskWithId:taskId stageAtIndex:0 status:PLTaskStageStatusSkipped];
        [manager setTaskWithId:taskId state:DownloadTaskStateCancelled];""",
    "ms-cancel-stage", marker="scan-d #8")

# ============ ④ ModsManager：通知类型过滤 + 导入重命名循环 ============
MM = "Natives/ModsManagerViewController.m"
patch(MM,
    r"""    if \(\[type isKindOfClass:\[NSString class\]\] && \[type isEqualToString:DownloadTaskResourceTypeMod\]\) \{""",
    """    // ★ Task268（scan-d #2）：恢复基类同款资源类型过滤——重写时丢失，
    //   MC 本体/JRE 等任意任务完成也触发 mods 全量重扫（无谓 IO + 日志刷屏）。
    static NSSet<NSString *> *ame268_resTypes = nil;
    static dispatch_once_t ame268_onceToken;
    dispatch_once(&ame268_onceToken, ^{
        ame268_resTypes = [NSSet setWithObjects:
            DownloadTaskResourceTypeMod,
            DownloadTaskResourceTypeShader,
            DownloadTaskResourceTypeResourcePack,
            DownloadTaskResourceTypeDataPack,
            DownloadTaskResourceTypeWorld,
            nil];
    });
    if (![type isKindOfClass:[NSString class]] || type.length == 0 ||
        ![ame268_resTypes containsObject:type]) return;
    if ([type isEqualToString:DownloadTaskResourceTypeMod]) {""",
    "mm-type-filter", marker="ame268_resTypes")

patch(MM,
    r"""            // 同名文件处理\n            if \(\[fm fileExistsAtPath:destPath\]\) \{\n                NSString \*baseName = \[fileName stringByDeletingPathExtension\];\n                NSString \*ext = \[fileName pathExtension\];\n                destPath = odsDir stringByAppendingPathComponent:\[NSString stringWithFormat:@"%@_copy.%@", baseName, ext\];\n            \}""",
    """            // 同名文件处理（★ Task268 scan-d #6：循环探测 _copy/_copy_N——
            //   旧版只试一次，_copy 也被占时 copyItemAtPath 直接失败）。
            if ([fm fileExistsAtPath:destPath]) {
                NSString *baseName = [fileName stringByDeletingPathExtension];
                NSString *ext = [fileName pathExtension];
                NSString *ame268_cand = nil;
                for (NSInteger ame268_n = 1; ame268_n < 1000; ame268_n++) {
                    NSString *ame268_name = (ame268_n == 1)
                        ? [NSString stringWithFormat:@"%@_copy.%@", baseName, ext]
                        : [NSString stringWithFormat:@"%@_copy_%ld.%@", baseName, (long)(ame268_n - 1), ext];
                    NSString *ame268_path = [odsDir stringByAppendingPathComponent:ame268_name];
                    if (![fm fileExistsAtPath:ame268_path]) { ame268_cand = ame268_path; break; }
                }
                if (ame268_cand) destPath = ame268_cand;
            }""",
    "mm-import-rename", marker="ame268_cand")

# ============ ⑤ input_bridge_v3.m：数字 GLFW 码 + URL 编码 + 键缓冲守卫 ============
IB = "Natives/input_bridge_v3.m"
patch(IB,
    r'if \(strcmp\(val, "key\.keyboard\.right\.shift"\) == 0 \|\| strcmp\(val, "54"\) == 0\) parsed = 344;\n                else if \(strcmp\(val, "key\.keyboard\.left\.shift"\) == 0 \|\| strcmp\(val, "42"\) == 0\) parsed = 340;',
    '''// ★ Task268（scan-c #1）：补 GLFW 数字形态（LWJGL3 340=LSHIFT/344=RSHIFT，
                //   42/54 为 LWJGL2 数字；两族不冲突）——1.13-1.21.x 整合包主力
                //   版本带若 options.txt 落数字形态，旧解析落 else=-1 → 344 直通
                //   = 右 SHIFT 死键复活带。
                if (strcmp(val, "key.keyboard.right.shift") == 0 || strcmp(val, "54") == 0 || strcmp(val, "344") == 0) parsed = 344;
                else if (strcmp(val, "key.keyboard.left.shift") == 0 || strcmp(val, "42") == 0 || strcmp(val, "340") == 0) parsed = 340;''',
    "ib-numeric-codes", marker='"344") == 0')

patch(IB,
    r'    return \[NSString stringWithFormat:@"%\@://%@\%@", prefix, path\];\n\}',
    '''    // ★ Task268（scan-c #2）：路径 percent-encode——含空格/非 URL 字符路径
    //   裸拼 scheme 使 URLWithString 返回 nil → openURL:nil 主线程抛异常。
    NSString *ame268_encoded = [path stringByAddingPercentEncodingWithAllowedCharacters:
        [NSCharacterSet URLPathAllowedCharacterSet]];
    if (!ame268_encoded) ame268_encoded = path;
    return [NSString stringWithFormat:@"%@://%@", prefix, ame268_encoded];
}''',
    "ib-url-encode", marker="ame268_encoded")

patch(IB,
    r"        keyDownBuffer\[MAX\(0, key-31\)\]=\(jbyte\)action;",
    '''        // ★ Task268（scan-c #5）：边界守卫——GLFW_KEY_LAST=348 时 key-31=317
        //   恰越界（缓冲 317 字节），自定义布局绑 Menu 即 1 字节堆越界写。
        int ame268_kidx = key - 31;
        if (ame268_kidx >= 0 && ame268_kidx < 317) keyDownBuffer[ame268_kidx]=(jbyte)action;''',
    "ib-kdb-guard", marker="ame268_kidx")

# ============ ⑥ SurfaceViewController.m：statsTimer 弱引用 + 滚轮单轴 ============
SV = "Natives/SurfaceViewController.m"
patch(SV,
    r"""    self\.statsTimer = \[NSTimer scheduledTimerWithTimeInterval:1\.0\n                                                      target:self\n                                                    selector:@selector\(updateGameStats\)\n                                                    userInfo:nil\n                                                     repeats:YES\];""",
    """    // ★ Task268（scan-a #1）：scheduledTimer target:self 保留环 → dealloc 永不
    //   可达 = 每次游戏会话泄漏整个 SurfaceViewController（视图树 + 观察者 +
    //   menuButton.menu）且 statsDisplayLink 120Hz 永久空转。改 block 定时器 +
    //   weakSelf（iOS 10+），dealloc 既有 invalidate 链恢复可达。
    __weak typeof(self) ame268_ws = self;
    self.statsTimer = [NSTimer timerWithTimeInterval:1.0
                                              repeats:YES
                                                block:^(NSTimer *t) {
        [ame268_ws updateGameStats];
    }];""",
    "sv-stats-timer", marker="ame268_ws")

patch(SV,
    r"""    mouse\.mouseInput\.scroll\.xAxis\.valueChangedHandler = \^\(GCControllerAxisInput \* _Nonnull axis, float value\) \{\n        CallbackBridge_nativeSendScroll\(value, value\);\n    \};\n    mouse\.mouseInput\.scroll\.yAxis\.valueChangedHandler = \^\(GCControllerAxisInput \* _Nonnull axis, float value\) \{\n        CallbackBridge_nativeSendScroll\(-value, -value\);\n    \};""",
    """    // ★ Task268（scan-c #4）：单轴滚动只喂单轴——旧版把值同时喂进双轴
    //   （垂直滚库存会横移创造标签页）。
    mouse.mouseInput.scroll.xAxis.valueChangedHandler = ^(GCControllerAxisInput * _Nonnull axis, float value) {
        CallbackBridge_nativeSendScroll(value, 0);
    };
    mouse.mouseInput.scroll.yAxis.valueChangedHandler = ^(GCControllerAxisInput * _Nonnull axis, float value) {
        CallbackBridge_nativeSendScroll(0, -value);
    };""",
    "sv-scroll-axes", marker="nativeSendScroll(value, 0)")

# ============ ⑦ osm_bridge.mm：realloc 守卫 + CGColorSpace 泄漏 ============
OSM = "Natives/ctxbridges/osm_bridge.mm"
patch(OSM,
    r"""    br_get_current\(\)->osm\.buffer = reallocf\(br_get_current\(\)->osm\.buffer, bufW \* bufH \* 4\);\n\n    handle\.OSMesaMakeCurrent\(br_get_current\(\)->osm\.context, br_get_current\(\)->osm\.buffer, GL_UNSIGNED_BYTE, bufW, bufH\);\n    handle\.OSMesaPixelStore\(OSMESA_ROW_LENGTH, bufW\);\n    handle\.OSMesaPixelStore\(OSMESA_Y_UP, 0\);\n\}""",
    """    // ★ Task268（scan-c #6）：reallocf 失败即释放旧缓冲返回 NULL → 后续
    //   MakeCurrent 绑 NULL（UAF/空绑定）。改 realloc：失败保旧缓冲跳过
    //   重绑（渲染用旧尺寸继续，限频日志）。
    void *ame268_buf = realloc(br_get_current()->osm.buffer, (size_t)bufW * (size_t)bufH * 4);
    if (ame268_buf != NULL) {
        br_get_current()->osm.buffer = ame268_buf;
        handle.OSMesaMakeCurrent(br_get_current()->osm.context, br_get_current()->osm.buffer, GL_UNSIGNED_BYTE, bufW, bufH);
        handle.OSMesaPixelStore(OSMESA_ROW_LENGTH, bufW);
        handle.OSMesaPixelStore(OSMESA_Y_UP, 0);
    } else {
        static bool ame268_logged = false;
        if (!ame268_logged) {
            NSLog("[osm] Task268: buffer realloc failed (%dx%d) -- keep old binding", bufW, bufH);
            ame268_logged = true;
        }
    }
}""",
    "osm-realloc", marker="ame268_buf")

patch(OSM,
    r"""    br_get_current\(\)->osm\.color_space = CGColorSpaceCreateDeviceRGB\(\);""",
    """    // ★ Task268（scan-c #8）：重复绑定先释放旧 CGColorSpaceRef（fixPojavGLContext
    //   重绑链每轮泄漏一个）。
    if (br_get_current()->osm.color_space) CGColorSpaceRelease(br_get_current()->osm.color_space);
    br_get_current()->osm.color_space = CGColorSpaceCreateDeviceRGB();""",
    "osm-colorspace", marker="CGColorSpaceRelease")

# ============ ⑧ AmeNativeMenu.m：早退分支补 onDismiss ============
patch("Natives/AmeNativeMenu.m",
    r"""    if \(menu == nil \|\| sourceView == nil\) return;\n    if \(menu\.children\.count == 0\) return; // 空菜单（全部项被丢弃）不呈现""",
    """    // ★ Task268（scan-a #5）：早退分支统一取消语义——空菜单/nil 锚点静默
    //   return 不回调 onDismiss，依赖 onDismiss 复位的调用方悬挂（同族
    //   alert==nil 路径按取消语义回调，口径不一致）。
    if (menu == nil || sourceView == nil || menu.children.count == 0) {
        if (onDismiss) onDismiss();
        return;
    }""",
    "amn-ondismiss", marker="ame268 onDismiss" if False else "if (onDismiss) onDismiss();\n        return;\n    }")

# ============ ⑨ DownloadViewController.m：JIT 等待自愈派发 + 可取消 ============
DV = "Natives/DownloadViewController.m"
# 两个 InlineMessageView 创建点后补 cancelled + close 钮
patch(DV,
    r"""(    InlineMessageView \*jitAlert = \[InlineMessageView showInViewController:self\n(?:[^#\n]*\n)*?                                                                    type:InlineMessageTypeLoading\];\n)""",
    lambda m: m.group(1) + """    // ★ Task268（scan-a #2）：等待期可取消（InlineMessageView 关闭钮接
    // ame267_cancelled，与 RightPanel/NavCtrl 同语义）+ 完成续接换
    // ame185 自愈派发（Task185 病历族：主队列楔死时裸 dispatch_async 静默丢块）。
    __block BOOL ame267_cancelled = NO;
    jitAlert.showsCloseButton = YES;
    jitAlert.onClose = ^{ ame267_cancelled = YES; };
""",
    "dv-cancel-ui", expect=2, marker="ame267_cancelled = NO;", flags=re.S)

patch(DV,
    r'(BOOL ok = ame169_waitForJITCondition\(\^\{ return )isJITEnabled\(false\)(; \}, 120\.0, @"isJITEnabled"\);)\n(        )dispatch_async\(dispatch_get_main_queue\(\), \^\{',
    r'\1(BOOL)(ame267_cancelled || isJITEnabled(false))\2\n\3ame185_dispatchToMainSelfHealing(^{',
    "dv-main-dispatch")

patch(DV,
    r'(BOOL ok = ame169_waitForJITCondition\(\^\{ return )JIT26IsLikelyDebuggerKeepAttached\(\)(; \}, 120\.0, @"JIT26 debugger attach"\);)\n(        )dispatch_async\(dispatch_get_main_queue\(\), \^\{',
    r'\1(BOOL)(ame267_cancelled || JIT26IsLikelyDebuggerKeepAttached())\2\n\3ame185_dispatchToMainSelfHealing(^{',
    "dv-reattach-dispatch")

patch(DV,
    r"""(            if \(ame172_bgt != UIBackgroundTaskInvalid\) \{\n                \[UIApplication\.sharedApplication endBackgroundTask:ame172_bgt\];\n                ame172_bgt = UIBackgroundTaskInvalid;\n            \}\n)(            if \(ok\) \{)""",
    r"""\1            if (ame267_cancelled) {
                NSLog(@"[JIT] [DownloadVC] Task268: JIT wait cancelled by user -- abandoning launch");
                return;
            }
\2""",
    "dv-cancel-branch", expect=2, marker="Task268: JIT wait cancelled by user")

print()

print()
if FAILURES:
    print("FAILURES:")
    for f in FAILURES:
        print(" -", f)
    sys.exit(1)
print("ALL R2 PATCHES OK")
