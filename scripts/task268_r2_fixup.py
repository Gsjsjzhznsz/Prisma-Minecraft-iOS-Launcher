#!/usr/bin/env python3
# Task 268 r2 补遗：修正 r2 批次中 5 个未命中/误跳过项
import re, sys

FAILURES = []

def patch(path, pattern, repl, label, expect=1, marker=None, flags=0):
    data = open(path, "rb").read().decode("utf-8")
    if marker and marker in data:
        print(f"SKIP {label}")
        return
    new, n = re.subn(pattern, repl, data, count=expect, flags=flags)
    if n != expect:
        FAILURES.append(f"{label}: {n}/{expect} in {path}")
        return
    open(path, "wb").write(new.encode("utf-8"))
    print(f"OK {label} x{n}")

# ① ib-url-encode：补 @ 前缀（ObjC 字面量 @"..."）
patch("Natives/input_bridge_v3.m",
    r'    return \[NSString stringWithFormat:@"%\@://%@\@", prefix, path\];\n\}',
    '''    // ★ Task268（scan-c #2）：路径 percent-encode——含空格/非 URL 字符路径
    //   裸拼 scheme 使 URLWithString 返回 nil → openURL:nil 主线程抛异常。
    NSString *ame268_encoded = [path stringByAddingPercentEncodingWithAllowedCharacters:
        [NSCharacterSet URLPathAllowedCharacterSet]];
    if (!ame268_encoded) ame268_encoded = path;
    return [NSString stringWithFormat:@"%@://%@", prefix, ame268_encoded];
}''',
    "ib-url-encode", marker="ame268_encoded")

# ② mm-import-rename：[modsDir …] 真身 + @ 前缀 + 行尾双 ]
patch("Natives/ModsManagerViewController.m",
    r'            if \(\[fm fileExistsAtPath:destPath\]\) \{\n                NSString \*baseName = \[fileName stringByDeletingPathExtension\];\n                NSString \*ext = \[fileName pathExtension\];\n                destPath = \[modsDir stringByAppendingPathComponent:\[NSString stringWithFormat:@"%@_copy.%@", baseName, ext\]\];\n            \}',
    '''            // 同名文件处理（★ Task268 scan-d #6：循环探测 _copy/_copy_N——
            // 旧版只试一次，_copy 也被占时 copyItemAtPath 直接失败）。
            if ([fm fileExistsAtPath:destPath]) {
                NSString *baseName = [fileName stringByDeletingPathExtension];
                NSString *ext = [fileName pathExtension];
                NSString *ame268_cand = nil;
                for (NSInteger ame268_n = 1; ame268_n < 1000; ame268_n++) {
                    NSString *ame268_name = (ame268_n == 1)
                        ? [NSString stringWithFormat:@"%@_copy.%@", baseName, ext]
                        : [NSString stringWithFormat:@"%@_copy_%ld.%@", baseName, (long)(ame268_n - 1), ext];
                    NSString *ame268_path = [modsDir stringByAppendingPathComponent:ame268_name];
                    if (![fm fileExistsAtPath:ame268_path]) { ame268_cand = ame268_path; break; }
                }
                if (ame268_cand) destPath = ame268_cand;
            }''',
    "mm-import-rename", marker="ame268_cand")

# ③ osm-colorspace：唯一 marker
patch("Natives/ctxbridges/osm_bridge.mm",
    r'    br_get_current\(\)->osm\.color_space = CGColorSpaceCreateDeviceRGB\(\);',
    '''    // ★ Task268（scan-c #8）：重复绑定先释放旧 CGColorSpaceRef（重绑链每轮泄漏）。
    if (br_get_current()->osm.color_space) CGColorSpaceRelease(br_get_current()->osm.color_space);
    br_get_current()->osm.color_space = CGColorSpaceCreateDeviceRGB();''',
    "osm-colorspace", marker="br_get_current()->osm.color_space) CGColorSpaceRelease")

# ④ amn-ondismiss：唯一 marker
patch("Natives/AmeNativeMenu.m",
    r'    if \(menu == nil \|\| sourceView == nil\) return;\n    if \(menu\.children\.count == 0\) return; // 空菜单（全部项被丢弃）不呈现',
    '''    // ★ Task268（scan-a #5）：早退分支统一取消语义——nil 锚点/空菜单静默
    //   return 不回调 onDismiss，依赖 onDismiss 复位的调用方悬挂。
    if (menu == nil || sourceView == nil || menu.children.count == 0) {
        if (onDismiss) onDismiss();
        return;
    }''',
    "amn-ondismiss", marker="menu == nil || sourceView == nil || menu.children.count == 0")

# ⑤ ps-uninstall：方法签名 marker（router 调用点已存在导致旧 marker 误跳）
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
    [self saveSettings]; // Task268：显式 @NO 保存口径
    NSLog(@"[ProfileSettings] Task268: TouchController uninstalled (%ld jar(s)) + profile key=NO for '%@'",
          (long)removed, ame268_prof);
    [self reloadAllTableViews];
}
'''
patch("Natives/ProfileSettingsViewController.m",
    r'(- \(void\)ame268_continueInstallTouchController \{\n)',
    lambda m: PS_UNINSTALL + "\n" + m.group(1),
    "ps-uninstall", marker="- (void)ame268_uninstallTouchController {")

print()
if FAILURES:
    print("FAILURES:")
    for f in FAILURES:
        print(" -", f)
    sys.exit(1)
print("R2 FIXUP ALL OK")
