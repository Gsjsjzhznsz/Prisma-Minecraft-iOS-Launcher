#!/usr/bin/env python3
# Task261：⑤ 设置页 air 旧数据导入入口 —— 3 新键 54 表覆盖
# 口径（Task 260 同款）：en/zh-CN/zh-Hans/zh-Hant 已有实译；其余 50 表
# 追加英文兜底文本到表尾。校验：引号/分号/值内无未转义引号。
import os, re, sys

ROOT = os.path.join(os.path.dirname(__file__), "..", "Natives", "resources")

EN = [
    ("preference.title.data_sibling_import",
     "Import old launcher data (air build)"),
    ("preference.detail.data_sibling_import",
     "Detect an old air-build app's data folder sitting next to this app (LiveContainer sibling layout) and merge it in with one tap. Same migration as the welcome wizard, always available here."),
    ("prefs.data_sibling.none",
     "No old launcher data found next to this app"),
    ("preference.title.done.data_sibling_import",
     "Import entry opened"),
]
# 中文三表实译（zh-Hans 已有；zh-CN/zh-Hant 亦已写入，脚本幂等跳过）
ZH = [
    ("preference.title.data_sibling_import", "导入旧版启动器数据（air 构建）"),
    ("preference.detail.data_sibling_import", "检测与本体并排的旧版 App（air 构建）数据目录（LiveContainer 兄弟布局），一键合并迁入。与欢迎向导同款迁移，此处随时可用。"),
    ("prefs.data_sibling.none", "未在本体旁发现旧版启动器数据"),
    ("preference.title.done.data_sibling_import", "已打开导入入口"),
]
ZHT = [
    ("preference.title.data_sibling_import", "匯入舊版啟動器資料（air 建置）"),
    ("preference.detail.data_sibling_import", "偵測與本體並排的舊版 App（air 建置）資料目錄（LiveContainer 相鄰版面），一鍵合併遷入。與歡迎精靈同款遷移，此處隨時可用。"),
    ("prefs.data_sibling.none", "未在本體旁發現舊版啟動器資料"),
    ("preference.title.done.data_sibling_import", "已開啟匯入入口"),
]

LOCALIZED = {
    "zh-CN.lproj": ZH,
    "zh-Hans.lproj": ZH,
    "zh-Hant.lproj": ZHT,
}

def esc(v):
    # .strings 值内引号/反斜杠转义
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
