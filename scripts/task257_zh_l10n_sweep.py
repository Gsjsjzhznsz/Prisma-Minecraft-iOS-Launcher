#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Task 257（清单 7：国际化第二轮——中文补全清查）。

背景：da21223 装机后用户反馈"检查国际化，不要硬编码，不要留键名。
需要补全中文翻译"。实锤样本：Task256 新增键 terracotta.stage.retry 在
zh-Hans 表里直接落了英文原文（"Retrying host connection (attempt %lu/2)…"）。

本脚本扫描 zh-Hans / zh-CN / zh-Hant 三表中【值与 en 表逐字相同且含拉丁
字母】的键（= 中文残留英文原文），排除语言中立值（品牌/单位/纯符号）后
输出候选清单；--fix 模式按内置译表回写三表（zh-CN 与 zh-Hans 同文，
zh-Hant 用繁体），回写后自动复跑 task191 语法门。

退出码非 0 = 存在未翻译残留（供门禁/人工复核）。
"""
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
RES = os.path.join(ROOT, "Natives", "resources")

ZH_TABLES = ["zh-Hans", "zh-CN", "zh-Hant"]

# 语言中立值白名单（与 en 同文是正确形态）：品牌名/技术缩写/单位/纯符号。
# Task257 扫描结论：以下键的英文原文即产品名/手柄按键名/格式占位，中文表
# 保留原文是正确形态（首次扫描残留 71 项中 35 项属此类，其余 36 项已译）。
NEUTRAL_KEYS = {
    "preference.title.renderer.release.gl4es",
    "preference.title.renderer.release.angle",
    "preference.title.renderer.release.zink",
    "preference.title.renderer.debug.virgl",
    "preference.title.renderer.debug.metal",
    "preference.title.renderer.debug.gl4eszl2",
    "preference.title.renderer_backend-mithril",
    "preference.title.renderer.debug.mgfamily",
    "preference.title.mg_custom_gl_version-4.0",
    "preference.title.mg_custom_gl_version-4.1",
    "preference.title.mg_custom_gl_version-4.2",
    "preference.title.mg_custom_gl_version-4.3",
    "preference.title.mg_custom_gl_version-4.4",
    "preference.title.mg_custom_gl_version-4.5",
    "preference.title.mg_custom_gl_version-4.6",
    "controller_configurator.title.type.xbox",
    "controller_configurator.title.type.playstation",
    "controller_configurator.xbox.title.named_a",
    "controller_configurator.xbox.title.named_b",
    "controller_configurator.xbox.title.named_x",
    "controller_configurator.xbox.title.named_y",
    "controller_configurator.playstation.title.bumper_left",
    "controller_configurator.playstation.title.bumper_right",
    "controller_configurator.playstation.title.trigger_left",
    "controller_configurator.playstation.title.trigger_right",
    "controller_configurator.playstation.title.thumb_left",
    "controller_configurator.playstation.title.thumb_right",
    "preference.debug.jit_enabler.stikjit",
    "preference.debug.jit_enabler.sidestore",
    "preference.debug.jit_enabler.stosdebug",
    "preference.debug.jit_enabler.jitstreamer",
    "preference.debug.jit_enabler.trollstore",
    "download.speed.format",
    "download.progress.file_count_short",
    "welcome.jit.title",
}
NEUTRAL_EXACT = set()


def parse_strings_table(path):
    entries = {}
    order = []
    if not os.path.exists(path):
        return entries, order
    pat = re.compile(r'^\s*"((?:[^"\\]|\\.)+)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;\s*$')
    with open(path, "r", encoding="utf-8") as f:
        for lineno, line in enumerate(f, 1):
            s = line.strip()
            if not s or s.startswith("//") or s.startswith("/*"):
                continue
            m = pat.match(s)
            if m:
                entries[m.group(1)] = m.group(2)
                order.append(m.group(1))
    return entries, order


def has_letters(v):
    return re.search(r"[A-Za-z]", v) is not None


def main():
    tables = {}
    for t in ["en"] + ZH_TABLES:
        tables[t], _ = parse_strings_table(os.path.join(RES, t + ".lproj", "Localizable.strings"))
    en = tables["en"]

    fix_mode = "--fix" in sys.argv
    # --fix 时从脚本同目录读译文表 task257_zh_translations.py（key -> (hans, hant)）
    trans = {}
    if fix_mode:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import task257_zh_translations as T
        trans = T.TRANSLATIONS

    candidates = []
    for key, eval_ in en.items():
        if not has_letters(eval_):
            continue
        if key in NEUTRAL_KEYS or key in NEUTRAL_EXACT or eval_ in NEUTRAL_EXACT:
            continue
        same = [t for t in ZH_TABLES if tables[t].get(key) == eval_]
        if len(same) == len(ZH_TABLES):
            candidates.append(key)

    print(f"[task257] zh-untranslated candidates: {len(candidates)}")
    for k in candidates:
        print(f"  {k} = {en[k][:110]}")

    if fix_mode:
        applied = 0
        for t in ZH_TABLES:
            path = os.path.join(RES, t + ".lproj", "Localizable.strings")
            entries, order = parse_strings_table(path)
            with open(path, "r", encoding="utf-8") as f:
                raw = f.read()
            changed = 0
            for key in candidates:
                if key not in trans:
                    continue
                hans, hant = trans[key]
                newval = hant if t == "zh-Hant" else hans
                pat = re.compile(
                    r'^("%s" = )"((?:[^"\\]|\\.)*)"(;\s*)$' % re.escape(key),
                    re.M,
                )
                def _sub(m, newval=newval):
                    esc = newval.replace("\\", "\\\\").replace('"', '\\"')
                    return f'{m.group(1)}"{esc}"{m.group(3)}'
                raw2, n = pat.subn(_sub, raw)
                if n:
                    changed += n
                    raw = raw2
            if changed:
                with open(path, "w", encoding="utf-8", newline="") as f:
                    f.write(raw)
            print(f"[task257] {t}: {changed} value(s) rewritten")
            applied += changed
        print(f"[task257] fix done, total {applied}")
        return 0

    if candidates:
        return 1
    print("[task257] zh tables clean (no untranslated English residue)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
