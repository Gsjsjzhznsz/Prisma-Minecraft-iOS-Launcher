#!/usr/bin/env python3
# Task267：模组管理实例切换器 3 新键全表覆盖
# 口径（Task 260/261/264/266 同款）：en/zh-CN/zh-Hans/zh-Hant 实译；其余表追加英文兜底。
# resman.mods.profile_chip 单定位符 %@（实例名）。
import os

ROOT = os.path.join(os.path.dirname(__file__), "..", "Natives", "resources")

EN = [
    ("resman.mods.profile_chip", "Profile: %@ ▾"),
    ("resman.mods.profile_picker.title", "Choose the profile to manage"),
    ("resman.mods.profile_follow", "Follow the selected profile"),
]
ZH = [
    ("resman.mods.profile_chip", "实例：%@ ▾"),
    ("resman.mods.profile_picker.title", "选择要管理的实例"),
    ("resman.mods.profile_follow", "跟随当前选中实例"),
]
ZHT = [
    ("resman.mods.profile_chip", "實例：%@ ▾"),
    ("resman.mods.profile_picker.title", "選擇要管理的實例"),
    ("resman.mods.profile_follow", "跟隨當前選中實例"),
]

LOCALIZED = {
    "zh-CN.lproj": ZH,
    "zh-Hans.lproj": ZH,
    "zh-Hant.lproj": ZHT,
}


def esc(v):
    return v.replace("\\", "\\\\").replace('"', '\\"')


def main():
    changed, skipped = [], []
    for d in sorted(os.listdir(ROOT)):
        p = os.path.join(ROOT, d, "Localizable.strings")
        if not os.path.isfile(p):
            continue
        txt = open(p, encoding="utf-8").read()
        rows = LOCALIZED.get(d, EN)
        todo = [(k, v) for (k, v) in rows if f'"{k}"' not in txt]
        if not todo:
            skipped.append(d)
            continue
        if not txt.endswith("\n"):
            txt += "\n"
        block = "".join('"%s" = "%s";\n' % (k, esc(v)) for k, v in todo)
        txt += block
        open(p, "w", encoding="utf-8").write(txt)
        changed.append((d, len(todo)))
    print("CHANGED %d tables:" % len(changed))
    for d, n in changed:
        print("  %-16s +%d keys" % (d, n))
    print("SKIPPED (already complete) %d: %s" % (len(skipped), ", ".join(skipped)))


if __name__ == "__main__":
    main()
