#!/usr/bin/env python3
# verify_task142 -- Task 142 verifier: renderer selection collapsed to a single
# "mg" entry + external follow-global toggle + backend key independence.
# Usage: python3 scripts/verify_task141.py   (run from repo root)
import os, re, subprocess, sys

PASS = FAIL = 0
def check(name, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"  PASS  {name}")
    else:
        FAIL += 1
        print(f"  FAIL  {name}  {detail}")

def read(p):
    return open(p, encoding='utf-8', errors='replace').read()

print("== A. Core model (LauncherPreferences.h/.m) ==")
prefh = read('Natives/LauncherPreferences.h')
prefm = read('Natives/LauncherPreferences.m')
check("A1 RENDERER_KEY_MG define in header",
      '#define RENDERER_KEY_MG "mg"' in prefh)
check("A2 \"mg\" candidate entry in rendererCandidates (after auto, always listed)",
      re.search(r'@\{@"key": @ RENDERER_KEY_MG,\n\s*@"name": localize\(@"preference\.title\.renderer\.debug\.mgfamily", nil\),\n\s*@"file": @""\}', prefm) is not None and
      prefm.index('@{@"key": @"auto"') < prefm.index('@ RENDERER_KEY_MG,') < prefm.index('@ RENDERER_NAME_MTL_ANGLE,'))  # Task212 重锚：holy gl4es 表项退役，后继锚改为 ANGLE
check("A3 ame_effective_renderer head calls the migration",
      prefm.index('ame142_migrateRendererStorage();') < prefm.index('NSString *ame142_backend = ame142_effective_backend_key();'))
check("A4 mg branch resolves backend + dylib guard with default-backend fallback",
      '[renderer isEqualToString:@ RENDERER_KEY_MG]' in prefm and
      'ame_physical_renderer_dylib(ame142_backend.UTF8String)' in prefm and
      'if (rendererLibraryExists(@ RENDERER_NAME_MOBILEGL)) {\n            return @ RENDERER_NAME_MOBILEGL;\n        }\n        return @"auto";' in prefm)
check("A5 mg backend fallback toast shows the backend's real name (not 'mg')",
      'ame142_bname = ame142_fn[ame142_bi];' in prefm and
      'preference.warning.mg_backend_missing_dylib' in prefm)
check("A6 legacy family keys still resolve as-is via the explicit path (Task132-140 compat)",
      prefm.index('if (![renderer isEqualToString:@"auto"]) {') < prefm.index('NSString *ame138_physical'))
check("A7 ame142_effective_backend_key priority chain (a key > b legacy global family > c legacy tier > d default vulkan)",
      (lambda b: b.index('getPrefObject(@"mobileglues.renderer_backend")') < b.index('getPrefObject(@"video.renderer")') and
                 'ame142_legacy == 2) return @ RENDERER_NAME_MOBILEGL_GLES' in b and
                 'ame142_legacy == 3) return @ RENDERER_NAME_MITHRIL' in b and
                 b.rstrip().endswith('}'))(prefm.split('NSString* ame142_effective_backend_key(void) {')[1].split('\nNSString\* ame142_migrateRendererStorage')[0]))
check("A8 default backend is Vulkan direct (libMobileGL.dylib)",
      prefm.count('return @ RENDERER_NAME_MOBILEGL;\n}') >= 1 and
      '用户指定"默认vulkan"' in prefm)
check("A9 migration: global family key -> backend key + 'mg' + legacy tier retired",
      'setPrefObject(@"mobileglues.renderer_backend", ame142_vr);' in prefm and
      'setPrefObject(@"video.renderer", @ RENDERER_KEY_MG);' in prefm and
      'setPrefInt(@"mobileglues.mobilegl_backend", 0);' in prefm)
check("A10 migration: profiles in-place rewrite + single save",
      'NSMutableDictionary *ame142_profiles = PLProfiles.current.profiles;' in prefm and
      '[PLProfiles.current save];' in prefm and
      '[ame142_profiles[ame142_name] isKindOfClass:NSDictionary.class]' in prefm)
check("A11 migration is idempotent (static sentinel)",
      'static BOOL ame142_done = NO;\n    if (ame142_done) return;' in prefm)
check("A12 display helper: mg + family keys all display 'mg'",
      '[renderer isEqualToString:@ RENDERER_KEY_MG] ||' in prefm and
      'preference.title.renderer.debug.mgfamily' in prefm)
check("A13 both helpers declared in header",
      'void ame142_migrateRendererStorage(void);' in prefh and
      'NSString* ame142_effective_backend_key(void);' in prefh)

print("== B. Settings page (LauncherPreferencesViewController.m) ==")
lp = read('Natives/LauncherPreferencesViewController.m')
mgread = lp.split('[key isEqualToString:@"renderer_backend"]')[1][:900]
check("B1 backend row read = ame142_effective_backend_key (own-key semantics)",
      'return ame142_effective_backend_key();' in mgread and
      'getPrefObject(@"video.renderer")' not in mgread)
backend_write = lp.split('NSString *ame142_rbValue')[1][:1500]
check("B2 backend row writes ONLY its own key + retires the legacy tier",
      'setPrefObject(@"mobileglues.renderer_backend", ame142_rbValue);' in backend_write and
      'setPrefInt(@"mobileglues.mobilegl_backend", 0);' in backend_write)
check("B3 backend write no longer routes through ame140_writeRendererGlobal",
      'ame140_writeRendererGlobal' not in backend_write)
check("B4 Task150: settings renderer row retired (getPreference video.renderer branch gone)",
      'if ([section isEqualToString:@"video"] && [key isEqualToString:@"renderer"]) {' not in lp and
      'getPrefObject(@"video.renderer")' not in lp)
check("B5 Task150: global renderer write + shadow toast retired",
      'setPrefObject(@"video.renderer"' not in lp and
      '"preference.warning.renderer_shadowed_by_profile"' not in lp)
check("B6 Task150: migration still runs in viewDidLoad; rendererKeys/rendererList properties retired",
      'ame142_migrateRendererStorage();' in lp and
      'self.rendererKeys' not in lp and
      '@property(nonatomic) NSArray<NSString*> *rendererKeys' not in lp)

print("== C. Game editor (ProfileSettingsViewController.m) ==")
ps = read('Natives/ProfileSettingsViewController.m')
check("C1 Task150: advanced rows start at the renderer row (follow-global toggle retired)",
      '@[@"渲染器"]' in ps and
      '@"跟随全局渲染器"' not in ps)
check("C2 Task150: toggle title mapping gone (renderer row keeps its own key)",
      '"preference.profile.renderer_follow_global_toggle"' not in ps and
      '@"渲染器": @"preference.title.renderer",' in ps)
check("C3 Task150: follow-global switch builder/handler retired",
      '- (UISwitch *)buildRendererFollowSwitch' not in ps and
      '- (void)rendererFollowSwitchChanged' not in ps)
check("C4 Task150: renderer row always active (no gray state, no nil guard)",
      'cell.detailTextLabel.text = [self rendererDisplayName:self.selectedRenderer];' in ps and
      '[self rendererDisplayName:nil]' not in ps and
      'if (self.selectedRenderer != nil) {' not in ps)
check("C5 picker is the single slim classic list (no family loop, no follow action)",
      ps.count('NSArray *renderers = getRendererKeys(NO);') == 1 and
      ps.count('NSArray *familyKeys = getRendererFamilyKeys();') == 0 and
      'ame140_followTitle' not in ps)
check("C6 legacy family keys checkmark onto the single mg entry",
      '[renderer isEqualToString:@ RENDERER_KEY_MG] &&' in ps and
      '[getRendererFamilyKeys() containsObject:self.selectedRenderer]' in ps)
check("C7 loadSettings migrates first and normalizes family keys to 'mg'",
      ps.index('ame142_migrateRendererStorage();') < ps.index('id ame140_rendererRaw = self.profile[@"renderer"];') and
      'ame140_rendererRaw = @ RENDERER_KEY_MG;' in ps)
check("C8 Task150: saveSettings writes explicit values (missing -> auto, key never removed)",
      'existing[@"renderer"] = @"auto";' in ps and
      '[existing removeObjectForKey:@"renderer"];' not in ps)
check("C9 Task150: renderer row tap opens the picker unconditionally",
      '[self showRendererSelector];' in ps)
check("C10 Task150: popover anchor moved to row 0 (renderer row is first again)",
      '[self cellForGlobalSection:3 row:0];' in ps)
check("C11 Task150: loadSettings defaults missing keys to auto; display helper nil->auto",
      '? ame140_rendererRaw : @"auto";' in ps and
      'return ame_renderer_display_name(@"auto");' in ps)
check("C12 follow-global picker-format l10n key no longer referenced",
      'preference.profile.renderer_follow_global"' not in ps)

print("== D. l10n (4 languages) ==")
langs = ['en.lproj', 'zh-Hans.lproj', 'zh-CN.lproj', 'zh-Hant.lproj']
base = 'Natives/resources/'
sets = []
for lg in langs:
    s = read(base + lg + '/Localizable.strings')
    n1 = '"preference.profile.renderer_follow_global_toggle"' not in s
    n2 = '"preference.title.renderer.debug.mgfamily"' in s
    n3 = '"preference.warning.mg_backend_missing_dylib"' in s
    n4 = '"preference.profile.renderer_follow_global"' not in s
    n5 = 'Vulkan 直连（默认）' in s or 'Vulkan direct (default)' in s or 'Vulkan 直連（預設）' in s
    check(f"D[{lg}] key set (toggle + mg + backend-warn; picker key retired; detail reworded)",
          n1 and n2 and n3 and n4 and n5)
    sets.append(set(re.findall(r'^"([^"]+)"\s*=', s, re.M)))
check("D5 Task150: four-language key sets identical (Task222 重锚：2715 = 2520 + 陶瓦联机 21 + 捐赠 7 + 向导介绍页 12)",
      sets[0] == sets[1] == sets[2] == sets[3] and len(sets[0]) == 2763,
      f"counts={[len(x) for x in sets]}")

print("== E. Publish assets ==")
import json
ann = json.load(open('announcements.json', encoding='utf-8'))
e = next((a for a in ann['announcements'] if a.get('id') == 'v6-0-0-release-2026-09-21'), None)
assert e is not None, 'v6-0-0-release entry missing'  # Task212 重锚：按 id 定位（公告序在 Task209/211/212 三轮 @2 插入后已非首位）
check("E1 announcements summary mentions mg single entry",
      'mg 单入口' in e['summary'])
check("E2 Task150: announcements bullet describes per-game mandatory selection + sodium install",
      '每游戏强制单选' in e['content'] and '缺省\"自动\"' in e['content'] and '唯一的 **mg** 条目' in e['content'] and 'Sodium' in e['content'])
check("E3 stale Task139 dual-write bullet removed",
      '设置页的选择现在与实例配置同步写入' not in e['content'])
check("E4 Task150: English tail re-worded to per-game mandatory selection",
      'per-game mandatory' in e['content'] and 'no global default' in e['content'])
# Task222：README 重构——README.md 现为中文默认，英文移至 README_EN.md
rcn = read('README.md'); ren = read('README_EN.md')
check("E5 Task150: README_CN renderer row per-game mandatory",
      '每游戏强制单选' in rcn and '缺省\"自动\"' in rcn and '唯一的 mg 条目' in rcn)
check("E6 Task150: README EN renderer row per-game mandatory",
      'per-game mandatory' in ren and 'single mg entry' in ren)
vh = read('Natives/external/MobileGlues/MobileGlues-cpp/version.h')
check("E7 version.h Task 142 addendum",
      'REVISION 17 addendum (Task 142, no bump)' in vh and
      'renderer selection collapsed to a' in vh)

print("== F. Downstream single-source consistency (audit) ==")
jl = read('Natives/JavaLauncher.m')
gb = read('Natives/ctxbridges/gl_bridge.m')
gsv = read('Natives/GameSurfaceView.m')
vm = read('Natives/VersionManagerViewController.m')
check("F1 JavaLauncher resolves AMETHYST_RENDERER via ame_effective_renderer (no local re-derivation)",
      'NSString *renderer = ame_effective_renderer();' in jl and
      'setenv("AMETHYST_RENDERER", renderer.UTF8String, 1);' in jl)
check("F2 egl_bridge consumes the env var (family keys flow unchanged)",
      'NSString *renderer = NSProcessInfo.processInfo.environment[@"AMETHYST_RENDERER"];' in read('Natives/egl_bridge.m'))
check("F3 layerClass uses the same single source (Task124 discipline)",
      'NSString *renderer = ame_effective_renderer();' in gsv)
check("F4 JavaLauncher MobileGL env keys off the RESOLVED family key",
      '[renderer isEqualToString:@ RENDERER_NAME_MOBILEGL_GLES]' in jl)
check("F5 VersionManager maps the mg key + migrates before reading keys",
      # Task 144 re-anchor：显示名 "mg" -> "MobileGlues"（用户指令"把mg改成全名"；
      # 逻辑键 RENDERER_KEY_MG="mg" 不变，仅短名映射改为全名）。
      '@ RENDERER_KEY_MG: @"MobileGlues",' in vm and
      vm.index('ame142_migrateRendererStorage();') < vm.index('self.rendererKeys = getRendererKeys(NO);'))
check("F6 verify_task140 fully green (re-anchored to Task142)",
      subprocess.run([sys.executable, 'scripts/verify_task140.py'],
                     capture_output=True, text=True).returncode == 0)

print(f"\n==== RESULT: {PASS} passed, {FAIL} failed ====")
sys.exit(1 if FAIL else 0)
