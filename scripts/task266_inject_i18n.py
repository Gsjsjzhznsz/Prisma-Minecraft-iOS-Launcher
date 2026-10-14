#!/usr/bin/env python3
# Task266：跨实例下载横幅 2 新键全表覆盖
# 口径（Task 260/261/264 同款）：en/zh-CN/zh-Hans/zh-Hant 实译；其余表追加英文兜底。
# 三参数用定位符 %1$@/%2$@/%3$@（文件名/目标实例/当前查看实例），语序可安全调换。
import os

ROOT = os.path.join(os.path.dirname(__file__), "..", "Natives", "resources")

EN = [
    ("resman.mods.cross_profile.text",
     "%1$@ was downloaded to instance \\u201c%2$@\\u201d (this page is showing \\u201c%3$@\\u201d)"),
    ("resman.mods.cross_profile.switch",
     "Switch to that instance"),
]
ZH = [
    ("resman.mods.cross_profile.text",
     "已下载的 %1$@ 写入了实例「%2$@」（当前查看的是「%3$@」）"),
    ("resman.mods.cross_profile.switch",
     "切换到该实例查看"),
]
ZHT = [
    ("resman.mods.cross_profile.text",
     "已下載的 %1$@ 寫入了實例「%2$@」（當前查看的是「%3$@」）"),
    ("resman.mods.cross_profile.switch",
     "切換到該實例查看"),
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
