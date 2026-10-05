#!/usr/bin/env python3
# task139_syntax_gate.py -- Task220 in-repo rebuild of the lost outer gate
# (task82 gateway adoption precedent). Interface unchanged: prints
# "all balanced" on success. Ten files = the Task139 touched set; skips
# backslash macro-continuation lines (they may legitimately carry unbalanced
# brackets in stringized macro bodies).
import os, sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

FILES = [
    "Natives/audio_capture_bridge.m",
    "Natives/SurfaceViewController.m",
    "Natives/JavaLauncher.m",
    "Natives/LauncherPreferencesViewController.m",
    "Natives/ProfileSettingsViewController.m",
    "Natives/LauncherRightPanelViewController.m",
    "Natives/LauncherRootViewController.m",
    "Natives/utils.h",
    "Natives/ctxbridges/mgl_fsr.mm",
    "Natives/ctxbridges/osm_bridge.mm",
]

def strip_strings_comments(text):
    out, i, n, mode = [], 0, len(text), 0
    while i < n:
        c = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        if mode == 0:
            if c == '"':
                mode = 1
            elif c == "'":
                mode = 2
            elif c == "/" and nxt == "/":
                mode = 3; i += 1
            elif c == "/" and nxt == "*":
                mode = 4; i += 1
            elif c in "([{)]}":
                out.append(c)
        elif mode == 1:
            if c == "\\":
                i += 1
            elif c == '"':
                mode = 0
        elif mode == 2:
            if c == "\\":
                i += 1
            elif c == "'":
                mode = 0
        elif mode == 3:
            if c == "\n":
                mode = 0
        elif mode == 4:
            if c == "*" and nxt == "/":
                mode = 0; i += 1
        i += 1
    return "".join(out)

bad = []
for rel in FILES:
    p = os.path.join(REPO, rel)
    with open(p, encoding="utf-8", errors="replace") as f:
        raw = f.read()
    # 宏续行跳过：行尾反斜杠的续行整族跳过（字符串化宏体可合法含不配对括号）
    kept_lines, skip_next = [], False
    for line in raw.split("\n"):
        if skip_next:
            skip_next = line.rstrip().endswith("\\")
            continue
        if line.rstrip().endswith("\\"):
            skip_next = True
            continue
        kept_lines.append(line)
    stripped = strip_strings_comments("\n".join(kept_lines))
    ok = (stripped.count("(") == stripped.count(")")
          and stripped.count("[") == stripped.count("]")
          and stripped.count("{") == stripped.count("}"))
    print(("balanced  " if ok else "UNBALANCED  ") + rel
          + ("" if ok else "  (%d/%d [%d/%d {%d/%d)" % (
              stripped.count("("), stripped.count(")"),
              stripped.count("["), stripped.count("]"),
              stripped.count("{"), stripped.count("}"))))
    if not ok:
        bad.append(rel)

if bad:
    print("NOT balanced: " + ", ".join(bad))
    sys.exit(1)
print("all balanced")
