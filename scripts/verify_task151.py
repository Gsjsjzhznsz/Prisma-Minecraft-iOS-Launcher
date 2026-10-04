#!/usr/bin/env python3
"""Task151 verifier: Bing daily wallpaper feature.

Checks: A new files & balance / B Bing API correctness / C BackgroundManager
source-tag integration / D settings page wiring / E launch hook / F build
wiring / G l10n (4x1952, bing keys) + Info.plist / H re-anchored gates clean.
"""
import os
import re
import subprocess
import sys

REPO = os.environ.get("AME_REPO", "/home/z/my-project/Amethyst-iOS-MyRemastered")
FAILED = []
PASSED = 0


def check(name, cond, detail=""):
    global PASSED
    if cond:
        PASSED += 1
        print(f"  [PASS] {name}")
    else:
        FAILED.append(name)
        print(f"  [FAIL] {name}  {detail}")


def rd(rel):
    with open(os.path.join(REPO, rel), encoding="utf-8") as f:
        return f.read()


def balance(path_rel):
    """Brace balance ignoring strings/comments; macro-continuation safe."""
    src = rd(path_rel)
    depth = 0
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c == '"':
            i += 1
            while i < n and src[i] != '"':
                if src[i] == "\\":
                    i += 1
                i += 1
        elif c == "'":
            i += 1
            while i < n and src[i] != "'":
                if src[i] == "\\":
                    i += 1
                i += 1
        elif src.startswith("//", i):
            while i < n and src[i] != "\n":
                i += 1
        elif src.startswith("/*", i):
            j = src.find("*/", i + 2)
            i = n if j < 0 else j + 2
            continue
        elif c in "{}":
            depth += 1 if c == "{" else -1
        i += 1
    return depth


def main():
    print("== A. New files & balance ==")
    new_files = [
        "Natives/BingWallpaperManager.h",
        "Natives/BingWallpaperManager.m",
        "Natives/BingWallpaperGalleryViewController.h",
        "Natives/BingWallpaperGalleryViewController.m",
    ]
    for f in new_files:
        p = os.path.join(REPO, f)
        check(f"A {f} exists", os.path.exists(p))
    for f in ["Natives/BingWallpaperManager.m", "Natives/BingWallpaperGalleryViewController.m"]:
        d = balance(f)
        check(f"A {os.path.basename(f)} brace-balanced", d == 0, f"depth={d}")

    print("== B. Bing API correctness ==")
    mgr = rd("Natives/BingWallpaperManager.m")
    hdr = rd("Natives/BingWallpaperManager.h")
    check("B HPImageArchive endpoint", "HPImageArchive.aspx?format=js&idx=0&n=8&mkt=zh-CN" in mgr)
    check("B dual-host fallback (cn then www)",
          mgr.index("https://cn.bing.com") < mgr.index("https://www.bing.com"))
    check("B UHD variant derivation", '"_1920x1080" withString:@"_UHD"' in mgr)
    check("B thumbnail w param", '&w=%ld' in mgr)
    check("B UHD fallback to original", "uhdImageURL" in mgr and "item.imageURL" in mgr)
    check("B 4h refresh throttle", "kBingMinRefreshInterval" in mgr and "4.0 * 3600" in mgr)
    check("B disk cache under Application Support/BingWallpaper",
          "NSApplicationSupportDirectory" in mgr and '@"BingWallpaper"' in mgr)
    check("B enabled defaults ON (nil -> YES)",
          "objectForKey:kBingEnabledKey" in mgr and "return YES" in mgr)
    check("B notification exported", "BingWallpaperDidUpdateNotification" in hdr and
          "BingWallpaperDidUpdateNotification = " in mgr)
    check("B user-custom priority guard in auto path",
          mgr.count('hasBackground] && ![bg isBingSource]') >= 1 and
          '![bgManager isBingSource]' in mgr)

    print("== C. BackgroundManager source tag ==")
    bm_h = rd("Natives/BackgroundManager.h")
    bm = rd("Natives/BackgroundManager.m")
    check("C header declares isBingSource + setter", "isBingSource" in bm_h and
          "setBingBackgroundImageAtPath" in bm_h)
    check("C source key persisted", 'kBackgroundSourceKey = @"background_source"' in bm)
    check("C legacy data treated as user",
          'self.backgroundSource = (self.currentType != BackgroundTypeNone) ? @"user" : nil;' in bm)
    check("C setImage marks user", 'self.currentType = BackgroundTypeImage;\n            self.currentBackgroundPath = filePath;\n            self.backgroundSource = @"user";' in bm)
    check("C setVideo marks user", 'self.currentType = BackgroundTypeVideo;\n            self.currentBackgroundPath = filePath;\n            self.backgroundSource = @"user";' in bm)
    check("C bing setter tags bing & reuses path (no copy)",
          'self.backgroundSource = @"bing";' in bm and "UIImageJPEGRepresentation" not in
          bm[bm.index("setBingBackgroundImageAtPath:(NSString *)path"):bm.index("- (void)setVideoBackgroundWithURL")])
    check("C clear deletes only inside backgrounds/",
          "[self.currentBackgroundPath hasPrefix:folder]" in bm)
    check("C clear resets source", bm.count("self.backgroundSource = nil;") >= 2)

    print("== D. Settings page wiring ==")
    bs = rd("Natives/BackgroundSettingsViewController.m")
    check("D sections[2] has header+3 rows",
          'localize(@"bing.section.header", nil), localize(@"bing.toggle.title", nil), localize(@"bing.gallery.title", nil), localize(@"bing.refresh.title", nil)' in bs)
    check("D old sections renumbered (3=image/video, 4=restore/clear)",
          "indexPath.section == 3" in bs and "indexPath.section == 4" in bs)
    check("D toggle cell with UISwitch tag 400", 'dequeueReusableCellWithIdentifier:@"BingToggleCell"' in bs and "bingSwitch.tag = 400" in bs)
    check("D status detail", "- (NSString *)bingStatusText" in bs and 'bing.status.today' in bs)
    check("D toggle handler applies/clears", "- (void)bingToggleChanged:" in bs and
          "autoRefreshAndApplyIfEnabled" in bs and "isBingSource" in bs)
    check("D gallery push", "BingWallpaperGalleryViewController galleryController" in bs and
          "pushViewController:gallery" in bs)
    check("D manual refresh row", "- (void)refreshBingManually" in bs)
    check("D footer hint", "titleForFooterInSection" in bs and "bing.footer.hint" in bs)
    check("D update notification observed", "handleBingUpdate" in bs and
          "name:BingWallpaperDidUpdateNotification" in bs)
    check("D clear paths re-apply bing", bs.count("[[BingWallpaperManager sharedManager] autoRefreshAndApplyIfEnabled];") >= 3)

    print("== E. Launch hook ==")
    sd = rd("Natives/SceneDelegate.m")
    check("E SceneDelegate import", '#import "BingWallpaperManager.h"' in sd)
    check("E auto refresh after applyBackgroundToWindow",
          sd.index("applyBackgroundToWindow:self.window") < sd.index("autoRefreshAndApplyIfEnabled"))

    print("== F. Build wiring ==")
    cm = rd("Natives/CMakeLists.txt")
    check("F CMake lists both new sources",
          "BingWallpaperManager.m" in cm and "BingWallpaperGalleryViewController.m" in cm)

    print("== G. l10n & Info.plist ==")
    bing_keys = ["bing.section.header", "bing.toggle.title", "bing.status.today",
                 "bing.status.unsynced", "bing.gallery.title", "bing.refresh.title",
                 "bing.footer.hint", "bing.gallery.nav.title", "bing.setwallpaper.title",
                 "bing.save.title", "bing.apply.success", "bing.apply.failed",
                 "bing.save.success", "bing.save.failed", "bing.download.hint",
                 "bing.refresh.done", "bing.refresh.failed"]
    gate_langs = ["en", "zh-Hans", "zh-CN", "zh-Hant"]
    counts = {}
    for lang in gate_langs:
        s = rd(f"Natives/resources/{lang}.lproj/Localizable.strings")
        ks = set(re.findall(r'^"([^"]+)"\s*=', s, re.M))
        counts[lang] = len(ks)
        missing = [k for k in bing_keys if k not in ks]
        check(f"G {lang} has all {len(bing_keys)} bing keys", not missing, f"missing={missing}")
    check("G gated baseline 2228 x4", len(set(counts.values())) == 1 and
          counts["en"] == 2482, str(counts))
    for lang in ["ja", "km"]:
        s = rd(f"Natives/resources/{lang}.lproj/Localizable.strings")
        ks = set(re.findall(r'^"([^"]+)"\s*=', s, re.M))
        missing = [k for k in bing_keys if k not in ks]
        check(f"G {lang} bing keys present (ungated)", not missing, f"missing={missing}")
    plist = rd("Natives/Info.plist")
    check("G NSPhotoLibraryAddUsageDescription present",
          "NSPhotoLibraryAddUsageDescription" in plist)

    print("== H. Re-anchored gates ==")
    stale = []
    for fn in sorted(os.listdir(os.path.join(REPO, "scripts"))):
        if not (fn.startswith("verify_task") and fn.endswith(".py")) or fn == "verify_task151.py":
            continue
        s = rd(f"scripts/{fn}")
        # Task168：l10n 基线 2228 -> 1954（净增 background.cards.neumorph.title），
        # 本检查语义 = "所有脚本计数锚与当前基线一致"，随基线诚实重锚。
        for m in re.finditer(r'len\(sets\[0\]\)\s*==\s*(\d+)', s):
            if m.group(1) != "2482":
                stale.append(f"{fn}:{m.group(1)}")
        for m in re.finditer(r'vals == \{(\d+)\}', s):
            if m.group(1) != "2482":
                stale.append(f"{fn}:vals{m.group(1)}")
    check("H no stale l10n anchors (expect 2482 everywhere (Task217 re-anchor: +36 keys, prior era retired), Task205 baseline)", not stale, str(stale))

    print(f"\n{'=' * 40}\n{PASSED} passed, {len(FAILED)} failed")
    if FAILED:
        for f in FAILED:
            print(f"  FAILED: {f}")
        sys.exit(1)
    print("ALL GREEN")


if __name__ == "__main__":
    main()
