#!/usr/bin/env python3
# Task267：四个 ModsManager 入口语义修正（字节级，保行尾/引号原样）
# - LauncherRoot/LauncherCardLayout 抽屉入口：删快照绑定 → 跟随模式（页面永不过期）
# - VersionManager/ProfileSettings 语义入口：改 ame267_pinToProfile:（钉定）
import re, sys

def patch(path, pattern, repl, label, expect=1):
    with open(path, "rb") as f:
        data = f.read().decode("utf-8")
    if repl in data:
        print(f"SKIP {label}: already applied")
        return
    new, n = re.subn(pattern, repl, data, count=expect)
    if n != expect:
        print(f"FAIL {label}: {n} match(es) in {path}", file=sys.stderr)
        sys.exit(1)
    with open(path, "wb") as f:
        f.write(new.encode("utf-8"))
    print(f"OK {label}: {n} replacement in {path}")

# ① LauncherRootViewController.m —— 抽屉入口删快照绑定（注释块一并退役）
patch(
    "Natives/LauncherRootViewController.m",
    r"""    // ★ Task265（模组管理"新装 mod 不显示"根修）：抽屉入口此前从未绑定\n(?: *//[^\n]*\n)*?    m\.profileName = PLProfiles\.current\.selectedProfileName;\n""",
    "    // ★ Task267：抽屉入口不再快照绑定 selectedProfileName（快照在页面存续期\n    //   永不过期 = 装机 3b97d2d 实锤的绑定旧实例根因）——默认跟随模式，\n    //   SelectedProfileChanged 实时换绑重扫（ModsManagerVC ame267 语义）。\n",
    "drawer-root-follow",
)

# ② LauncherCardLayoutViewController.m —— 同款
patch(
    "Natives/LauncherCardLayoutViewController.m",
    r"    // ★ Task265[^\n]*\n(?: *//[^\n]*\n)*?    m\.profileName = PLProfiles\.current\.selectedProfileName;\n",
    "    // ★ Task267：抽屉入口不再快照绑定（快照永不过期 = 绑定旧实例根因）——\n    //   默认跟随模式，实时跟随选中实例（详见 LauncherRootViewController 同款注释）。\n",
    "drawer-card-follow",
)

# ③ VersionManagerViewController.m —— 语义入口钉定
patch(
    "Natives/VersionManagerViewController.m",
    r"    ModsManagerViewController \*vc = \[\[ModsManagerViewController alloc\] init\];\n    vc\.profileName = self\.selectedProfile;\n",
    "    ModsManagerViewController *vc = [[ModsManagerViewController alloc] init];\n    // Task267：语义入口（管理此版本的模组）= 钉定该实例，选中实例变化不跟走\n    [vc ame267_pinToProfile:self.selectedProfile];\n",
    "versionmgr-pin",
)

# ④ ProfileSettingsViewController.m —— 语义入口钉定
patch(
    "Natives/ProfileSettingsViewController.m",
    r"    ModsManagerViewController \*vc = \[\[ModsManagerViewController alloc\] init\];\n    vc\.profileName = \[self currentProfileName\];\n",
    "    ModsManagerViewController *vc = [[ModsManagerViewController alloc] init];\n    // Task267：语义入口（本 gameDir 实例的模组）= 钉定，选中实例变化不跟走\n    [vc ame267_pinToProfile:[self currentProfileName]];\n",
    "profilesettings-pin",
)

print("ALL OK")
