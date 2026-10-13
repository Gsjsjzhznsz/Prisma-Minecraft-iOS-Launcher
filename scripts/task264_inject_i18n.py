#!/usr/bin/env python3
# Task264：模组管理"扫描目录提示行" 2 新键全表覆盖
# 口径（Task 260/261 同款）：en/zh-CN/zh-Hans/zh-Hant 实译；其余表追加英文兜底。
# 校验：引号/分号/值内无未转义引号。
import os

ROOT = os.path.join(os.path.dirname(__file__), "..", "Natives", "resources")

EN = [
    ("resman.mods.folder.caption",
     "Mods folder \\u2014 new .jar files go here"),
    ("resman.mods.folder.open",
     "Open mods folder in Files"),
]
ZH = [
    ("resman.mods.folder.caption",
     "模组目录 \\u2014 新 Mod 的 .jar 文件放这里"),
    ("resman.mods.folder.open",
     "在「文件」中打开模组目录"),
]
ZHT = [
    ("resman.mods.folder.caption",
     "模組目錄 \\u2014 新 Mod 的 .jar 檔案放這裡"),
    ("resman.mods.folder.open",
     "在「檔案」中開啟模組目錄"),
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
