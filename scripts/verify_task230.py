#!/usr/bin/env python3
"""verify_task230.py -- Task 230 (15-item feedback round) implementation gates.
Each check asserts a byte-level anchor in the edited files (display-layer
character-eating defense: pure substring membership, no regex ambiguity)."""
import os, sys, json, re

BASE = "/home/z/my-project/Amethyst-iOS-MyRemastered"
passed, failed = 0, []

def check(name, path, needle):
    global passed
    p = os.path.join(BASE, path)
    try:
        src = open(p, encoding="utf-8", errors="replace").read()
    except FileNotFoundError:
        failed.append(f"{name}: FILE MISSING {path}")
        return
    if needle in src:
        passed += 1
    else:
        failed.append(f"{name}: anchor missing in {path}")

# (1) 1.20.1 ANGLE crash: colon-aware stub signature + noNative
check("230-1a colon-aware stub", "Natives/JavaLauncher.m", "static BOOL ame230_addGenericNoop(Class cls, SEL name)")
check("230-1b Task99 uses it", "Natives/JavaLauncher.m", "if (!ame230_addGenericNoop(self, name)) return NO;")
check("230-1c noNative flag", "Natives/JavaLauncher.m", "-Dio.netty.transport.noNative=true")
# (5) LAN first-open crash: netty native dlopen block
check("230-5a netty dlopen block", "Natives/main_hook.m", 'strstr(path, "netty_transport_native") != NULL')
check("230-5b block log anchor", "Natives/main_hook.m", "[Amethyst] Task230: blocked dlopen of netty native transport")
# (2) input offset after backgrounding: DOWN re-anchor in grab mode
check("230-2a down re-anchor", "Natives/input_bridge_v3.m", "} else if (event == ACTION_DOWN) {")
check("230-2b baseline set", "Natives/input_bridge_v3.m", "cLastX = x;\n                cLastY = y;")
# (6) keyboard closes per input: adaptive debounce
check("230-6a char timestamp", "Natives/SurfaceViewController.m", "static CFAbsoluteTime ame230_lastCharForwardedAt = 0.0;")
check("230-6b adaptive delay", "Natives/SurfaceViewController.m", "ame230_resignDelay = (ame230_sinceChar < 2.0) ? 1.2 : 0.25;")
check("230-6c fire clears ptr", "Natives/SurfaceViewController.m", "ame223_pendingStopResign = NULL;   // ★ Task230")
# (10) auto keyboard switch: pref registered
check("230-10 pref registered", "Natives/PLPreferences.m", '@"auto_keyboard_sdl": @NO,')
# (14) font ghosting: zero-offset halo both sites
check("230-14a swizzle halo (Task232 重锚：⑯ 光晕退役，四方向外扩描边接管)", "Natives/BackgroundManager.m", "ame232_swizzledLabelDrawTextInRect")
check("230-14b adaptive halo (Task232 重锚：⑯ 光晕退役)", "Natives/BackgroundManager.m", "ame232_OutlineMarkKey")
# (12) welcome blank: tree exemption
check("230-12a tree api", "Natives/BackgroundManager.m", "void ame230_setViewTreeStrokeExempt(UIView *view, BOOL exempt)")
check("230-12b swizzle checks tree", "Natives/BackgroundManager.m", "if (ame230_viewTreeIsStrokeExempt((UILabel *)self)) return;")
check("230-12c wizard exempt", "Natives/WelcomeViewController.m", "ame230_setViewTreeStrokeExempt(self.view, YES);")
check("230-12d coachmarks exempt", "Natives/Ame223CoachMarksView.m", "ame230_setViewTreeStrokeExempt(self, YES);")
# (9) gear drag
check("230-9a manual tap-fire", "Natives/GameMenuOverlayView.m", "Task230 gear manual tap-fire")
check("230-9b caption label", "Natives/GameMenuOverlayView.m", "ame230_captionLabel.text = localize(@\"ame230.gamemenu.caption\", nil);")
check("230-9c no translationInView rejection", "Natives/GameMenuOverlayView.m", "if (ame229_pan.view == self.menuButton) {\n            return YES;\n        }")
# (8) SDL folder open: dlsym-path hook + solid FileList
check("230-8a dlsym OpenURL hook", "Natives/sdl3_hook.m", 'if (strcmp(name, "SDL_OpenURL") == 0) {')
check("230-8b FileList solid", "Natives/FileListViewController.m", "self.tableView.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];")
check("230-8c FileList exempt", "Natives/FileListViewController.m", "ame230_setViewTreeStrokeExempt(self.view, YES);")
# (4) floating menu glass: heavy material
check("230-4 heavy glass", "Natives/SurfaceViewController+Navigation.m", "UIBlurEffectStyleSystemMaterialDark")
# (7) wrong-loader deps: loader-aware picking both sides + quick entry
check("230-7a install loader check", "Natives/DownloadViewController.m", "BOOL (^ame230_loaderOK)(ModVersion *)")
check("230-7b skip on no match", "Natives/DownloadViewController.m", "dep skipped (no version matches loader=")
check("230-7c resolver fallback", "Natives/ModDependencyResolver.m", "if (picked == nil) picked = ame230_loaderOnly;")
check("230-7d quick entry", "Natives/ModVersionViewController.m", "ame230_openDependencyPage:(UIButton *)sender")
# Task236 诚实重锚：footer 已重构为模组列表同款富条目（图标+介绍内联+直跳
# 下载页），旧"Task230 dependency quick-entry footer"日志由 Task236 rich footer
# 日志接替；ⓘ 按钮仍走 ame230_openDependencyPage:（230-7d 不变）。
# Task238 诚实重锚：前置区从表尾上移到头部堆叠（详情头之下、版本列表
# 之上），日志文案随之升级；富条目渲染 + 直跳行为不变（230-7d 不变）。
check("230-7e quick entry log", "Natives/ModVersionViewController.m", "[ModVersionVC] Task238 dependency section pinned above version list:")
# (11) backup import: reload + refresh + summary
check("230-11a prefs reload", "Natives/DataTransferService.m", "loadPreferences(NO);")
check("230-11b root rebuild", "Natives/DataTransferService.m", 'postNotificationName:@"AppLanguageChanged"')
check("230-11c summary", "Natives/DataTransferService.m", "ame230.import.summary")
# (3) sprint: layout bind + migration + toast
for jf in ["Natives/resources/controlmap/custom.json", "controls/layouts/classic.json", "controls/layouts/large-buttons.json"]:
    try:
        d = open(os.path.join(BASE, jf), encoding="utf-8").read()
        j = json.loads(d)
        found = json.dumps(j, ensure_ascii=False)
        if '"常用\\n操作键"' in found or "常用" in found:
            # locate the button and assert 341
            def walk(o):
                if isinstance(o, dict):
                    if "常用" in str(o.get("name", "")) and isinstance(o.get("keycodes"), list):
                        return o["keycodes"][0] == 341
                    return any(walk(v) for v in o.values())
                if isinstance(o, list):
                    return any(walk(v) for v in o)
                return False
            if walk(j):
                passed += 1
            else:
                failed.append(f"230-3 layout not bound to 341: {jf}")
        else:
            failed.append(f"230-3 layout missing 常用 button: {jf}")
    except Exception as e:
        failed.append(f"230-3 layout parse error {jf}: {e}")
check("230-3b migration", "Natives/main.m", "sprint dead-button migrated to Left Control 341")
check("230-3c unbound toast (Task232 重锚：⑤ NMToast 退役，取证留日志层)", "Natives/SurfaceViewController.m", "Task229 UNBOUND button pressed")
# (13) control repo: upload + safety check
check("230-13a sanitizer", "Natives/ControlRepoViewController.m", "static BOOL ame230_layoutSafetyCheck(NSData *raw, id jsonObj, NSString **reasonOut)")
check("230-13b download check (Task232 重锚：⑮ 检查移到下载侧询问流)", "Natives/ControlRepoViewController.m", "ame232_layoutSafetyIssues")
check("230-13c upload flow", "Natives/ControlRepoViewController.m", "+ (void)ame230_presentUploadFlowFrom:(UIViewController *)presenter preselect:(NSString *)preselect")
check("230-13d header decl", "Natives/ControlRepoViewController.h", "+ (void)ame230_presentUploadFlowFrom:(UIViewController *)presenter preselect:(NSString *)preselect;")
check("230-13e editor entry", "Natives/CustomControlsViewController.m", "- (void)actionMenuUpload {")
check("230-13f github deeplink (Task233 重锚：URL 编码修复；Task234 重锚：filename=/value= 查询参数触发 GitHub 500 错误页——isaacs/github#1527 filename 斜杠已知 bug + value 大载荷渲染 500，改 /new/main/controls/layouts/community 纯路径目录预导航)", "Natives/ControlRepoViewController.m", "/new/%@/controls/layouts/community")
# (15) i18n: 18 keys x 5 langs
KEYS = ["ame230.gamemenu.caption", "ame230.deps.required",
        "ame230.deps.optional", "ame230.import.summary", "ame230.repo.upload",
        "ame230.repo.upload_editor", "ame230.repo.upload.pick", "ame230.repo.upload.form.title",
        "ame230.repo.upload.form.message", "ame230.repo.upload.name", "ame230.repo.upload.author",
        "ame230.repo.upload.desc", "ame230.repo.upload.github", "ame230.repo.upload.github_hint",
        "ame230.repo.upload.no_layouts", "ame230.repo.upload.invalid"]
for lang in ["en", "zh-Hans", "zh-Hant", "zh-CN", "ja"]:
    p = os.path.join(BASE, f"Natives/resources/{lang}.lproj/Localizable.strings")
    src = open(p, encoding="utf-8").read()
    miss = [k for k in KEYS if f'"{k}"' not in src]
    if miss:
        failed.append(f"230-15 i18n {lang} missing: {miss}")
    else:
        passed += 1

total = passed + len(failed)
print(f"verify_task230: {passed}/{total} checks passed")
if failed:
    print("FAILURES:")
    for f in failed:
        print(" -", f)
    sys.exit(1)
print("ALL GREEN")
