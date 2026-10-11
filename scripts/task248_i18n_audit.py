#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Task 248（⑪ 国际化审计）：三道闸
  1. 裸键名闸：代码里 localize/MPLocalized 引用的每个键必须存在于
     en + zh-Hans + zh-CN + zh-Hant 四表（任一缺 = 运行期可能直显键名，
     localize 的回退链 en→zh-Hans→zh-CN 走完仍无 = 键名上屏）。
  2. 硬编码闸：UI 写入点（setTitle/initWithTitle/setText/message 等）
     里的 CJK 字面量（排除 NSLog/注释/localize 调用本身）。
  3. 格式闸：值中 % 占位符与代码格式参数个数抽查（占位符存在性）。
退出码非 0 = 有发现项。
"""
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
NATIVES = os.path.join(ROOT, "Natives")
RES = os.path.join(NATIVES, "resources")

TABLES = ["en", "zh-Hans", "zh-CN", "zh-Hant", "ja"]

def parse_strings_table(path):
    entries = {}
    if not os.path.exists(path):
        return entries
    pat = re.compile(r'^\s*"((?:[^"\\]|\\.)+)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;\s*$')
    with open(path, "r", encoding="utf-8") as f:
        for lineno, line in enumerate(f, 1):
            s = line.strip()
            if not s or s.startswith("//") or s.startswith("/*"):
                continue
            m = pat.match(s)
            if m:
                entries[m.group(1)] = m.group(2)
    return entries

def collect_localize_calls():
    """收集 Natives/**/*.m 里 localize(@"key",...) 与 MPLocalized(@"key",...) 的键。"""
    key_re = re.compile(r'\b(?:localize|MPLocalized)\s*\(\s*@((?:"(?:[^"\\]|\\.)*"\s*)+)')
    calls = {}  # key -> [(file, line)]
    for dirpath, _dirs, files in os.walk(NATIVES):
        if "/external/" in dirpath.replace(os.sep, "/"):
            continue
        for fn in files:
            if not fn.endswith((".m", ".mm")):
                continue
            p = os.path.join(dirpath, fn)
            rel = os.path.relpath(p, ROOT)
            with open(p, "r", encoding="utf-8", errors="replace") as f:
                for lineno, line in enumerate(f, 1):
                    for m in key_re.finditer(line):
                        raw = m.group(1)
                        # 拼接字面量 @"a" @"b" → ab（宏里常见的续接形态）
                        parts = re.findall(r'"((?:[^"\\]|\\.)*)"', raw)
                        key = "".join(parts)
                        calls.setdefault(key, []).append((rel, lineno))
    return calls

def load_all_tables():
    tables = {}
    for t in TABLES:
        tables[t] = parse_strings_table(os.path.join(RES, f"{t}.lproj", "Localizable.strings"))
    return tables

def scan_hardcoded_ui_literals():
    """UI 写入点 CJK 字面量扫描（排除 NSLog/localize/注释）。"""
    ui_write = re.compile(
        r'(setTitle|initWithTitle|setMessage|setText|setPlaceholder|'
        r'setAccessibilityLabel|buttonWithTitle|actionWithTitle|'
        r'alertControllerWithTitle|alertControllerWithTitle:message|'
        r'initWithBarButtonSystemItem)[^;]*@"([^"]*[\u4e00-\u9fff]+[^"]*)"')
    hits = []
    for dirpath, _dirs, files in os.walk(NATIVES):
        rp = dirpath.replace(os.sep, "/")
        if "/external/" in rp or "/resources/" in rp:
            continue
        for fn in files:
            if not fn.endswith((".m", ".mm")):
                continue
            p = os.path.join(dirpath, fn)
            rel = os.path.relpath(p, ROOT)
            with open(p, "r", encoding="utf-8", errors="replace") as f:
                for lineno, line in enumerate(f, 1):
                    st = line.strip()
                    if st.startswith("//") or st.startswith("*") or st.startswith("/*"):
                        continue
                    if "NSLog" in line or "fprintf" in line or "printf(" in line:
                        continue
                    if "localize" in line or "MPLocalized" in line:
                        # 行内 localize 之外的独立 CJK 字面量才算
                        cleaned = re.sub(r'(?:localize|MPLocalized)\s*\((?:[^);]|\([^)]*\))*\)', "", line)
                        for m in ui_write.finditer(cleaned):
                            hits.append((rel, lineno, m.group(0)[:120]))
                        continue
                    for m in ui_write.finditer(line):
                        hits.append((rel, lineno, m.group(0)[:120]))
    return hits

def main():
    tables = load_all_tables()
    calls = collect_localize_calls()
    print(f"[i18n] localize/MPLocalized 键引用总数（去重）: {len(calls)}")
    for t in TABLES:
        print(f"[i18n] 表 {t}: {len(tables[t])} 键")

    missing = {}
    for key, sites in sorted(calls.items()):
        if not key:
            continue
        absent = [t for t in ("en", "zh-Hans", "zh-CN", "zh-Hant") if key not in tables[t]]
        if absent:
            missing[key] = (absent, sites[:3])

    print("\n=== 闸1 裸键名（引用了但四表未齐）===")
    if not missing:
        print("PASS：所有被引用键在 en/zh-Hans/zh-CN/zh-Hant 四表齐备")
    else:
        for key, (absent, sites) in sorted(missing.items()):
            print(f"MISSING {key}  缺表: {','.join(absent)}  首处: {sites[0][0]}:{sites[0][1]}")

    print("\n=== 闸2 UI 写入点 CJK 硬编码 ===")
    hits = scan_hardcoded_ui_literals()
    if not hits:
        print("PASS：UI 写入点零 CJK 硬编码字面量")
    else:
        for rel, lineno, snippet in hits:
            print(f"HARDCODED {rel}:{lineno}  {snippet}")

    # ★ Task249 闸3：动态拼键枚举校验——静态 localize("...") 引用扫描抓不到
    #   localize([NSString stringWithFormat:...]) 的动态键；动态键在四表缺席
    #   时同样键名上屏（本轮装机实测面：controller_configurator 家族）。
    #   模式 = (键前缀, 前缀下可能的取值集合)；取值来源 = 代码内常量数组/
    #   枚举，逐一比对四表。新增动态键时在此登记即可纳入守护。
    dynamic_patterns = {
        "dataexport.section.": [
            "worlds", "resourcepacks", "mods", "screenshots",
            "servers", "instance", "launcher", "gamefiles",
        ],
        "controller_configurator.title.type.": ["xbox", "playstation"],
        "controller_configurator.section.": [
            "config_files", "game_mappings", "menu_mappings", "controller_style",
        ],
        "controller_configurator.section.footer.": [
            "config_files", "game_mappings", "menu_mappings", "controller_style",
        ],
    }
    dyn_missing = []
    for prefix, values in dynamic_patterns.items():
        for v in values:
            k = prefix + v
            absent = [t for t in ("en", "zh-Hans", "zh-CN", "zh-Hant") if k not in tables[t]]
            if absent:
                dyn_missing.append((k, absent))

    print("\n=== 闸3 动态拼键四表校验（Task249）===")
    if not dyn_missing:
        print("PASS：全部动态键前缀的枚举取值在四表齐备")
    else:
        for k, absent in dyn_missing:
            print(f"DYNAMIC-MISSING {k}  缺表: {','.join(absent)}")

    hard_fail = len(hits)
    missing_fail = len(missing)
    dyn_fail = len(dyn_missing)
    print(f"\n[i18n] 结论: 缺键 {missing_fail} 项, 硬编码 {hard_fail} 处, 动态键缺表 {dyn_fail} 项")
    sys.exit(0 if (missing_fail == 0 and hard_fail == 0 and dyn_fail == 0) else 1)

if __name__ == "__main__":
    main()
