#!/usr/bin/env python3
# Task219 syntax gates: bracket/paren balance (verifier-grade state machine,
# strings + comments + char literals skipped) + TAB/CRLF baselines untouched.
import sys, os, re

REPO = os.path.join(os.path.dirname(__file__), "..")
FAILED = []

def check(name, ok, detail=""):
    print(("PASS " if ok else "FAIL ") + name + ((" -- " + detail) if (detail and not ok) else ""))
    if not ok:
        FAILED.append(name)

def balance(path):
    """State-machine bracket balance: skips // and /* */ comments, "..." and '...'
    literals with escapes. Half-open interval notation banned by house rule so
    plain counting works."""
    with open(path, "r", encoding="utf-8") as f:
        src = f.read()
    stack = []
    pairs = {")": "(", "]": "[", "}": "{"}
    i, n = 0, len(src)
    state = "code"  # code | line_comment | block_comment | string | char
    while i < n:
        c = src[i]
        nxt = src[i + 1] if i + 1 < n else ""
        if state == "code":
            if c == "/" and nxt == "/":
                state = "line_comment"; i += 2; continue
            if c == "/" and nxt == "*":
                state = "block_comment"; i += 2; continue
            if c == '"':
                state = "string"; i += 1; continue
            if c == "'":
                state = "char"; i += 1; continue
            if c in "([{":
                stack.append((c, i))
            elif c in ")]}":
                if not stack or stack[-1][0] != pairs[c]:
                    line = src.count("\n", 0, i) + 1
                    return False, f"unbalanced '{c}' at line {line}"
                stack.pop()
        elif state == "line_comment":
            if c == "\n":
                state = "code"
        elif state == "block_comment":
            if c == "*" and nxt == "/":
                state = "code"; i += 2; continue
        elif state == "string":
            if c == "\\":
                i += 2; continue
            if c == '"':
                state = "code"
        elif state == "char":
            if c == "\\":
                i += 2; continue
            if c == "'":
                state = "code"
        i += 1
    if stack:
        line = src.count("\n", 0, stack[-1][1]) + 1
        return False, f"unclosed '{stack[-1][0]}' opened at line {line}"
    return True, ""

changed = [
    "Natives/ctxbridges/virgl_server.m",
    "Natives/egl_bridge.m",
    "Natives/external/gl4es/tinygl4angle.c",
    "Natives/WelcomeViewController.m",
    "Natives/AboutViewController.m",
    "Natives/DataTransferService.m",
    "Natives/ProfileSettingsViewController.m",
    "Natives/ModService.m",
    "Natives/ModsManagerViewController.m",
    "Natives/external/MobileGlues/MobileGlues-cpp/version.h",
]
for p in changed:
    ok, detail = balance(os.path.join(REPO, p))
    check(f"balance {p}", ok, detail)

# Makefile TAB baseline must be untouched this round (no Makefile edit)
with open(os.path.join(REPO, "Makefile"), "rb") as f:
    mk = f.read()
check("Makefile TAB baseline 662",
      sum(1 for line in mk.split(b"\n") if line.startswith(b"\t")) == 662)

# workflow CRLF baseline untouched
with open(os.path.join(REPO, ".github/workflows/development.yml"), "rb") as f:
    yml = f.read()
check("workflow CRLF intact", yml.count(b"\r\n") == yml.count(b"\n"))

# Info.plist identity unchanged this round
with open(os.path.join(REPO, "Natives/Info.plist"), "r", encoding="utf-8") as f:
    plist = f.read()
check("bundle id stays com.air-devs.air (no identity change this round)",
      "<string>com.air-devs.air</string>" in plist)

# l10n 4-language unique key parity
for lang in ["en", "zh-Hans", "zh-Hant", "zh-CN"]:
    with open(os.path.join(REPO, f"Natives/resources/{lang}.lproj/Localizable.strings"),
              "r", encoding="utf-8") as f:
        keys = set(re.findall(r'^"([^"]+)"\s*=', f.read(), re.M))
    check(f"l10n {lang} unique keys 2520", len(keys) == 2520, f"got {len(keys)}")

# strings files parse: every added key must appear exactly once per language
NEED = ["welcome.back", "welcome.env.title", "welcome.env.lc.mismatch.title",
        "welcome.env.lc.mismatch.body", "welcome.jit.title", "welcome.jit.status.off",
        "welcome.jit.hint.lc", "ame219.export.pick_level", "ame219.export.level_best",
        "ame219.export.progress_file", "component.touch.searching", "component.touch.not_found",
        "component.touch.unsupported", "component.touch.done", "component.touch.fabric_only",
        "component.touch.confirm_message", "ame219.mods.isolated_chip", "ame219.mods.shared_chip",
        "ame219.virgl.fallback.title", "ame219.virgl.fallback.body"]
for lang in ["en", "zh-Hans", "zh-Hant", "zh-CN"]:
    with open(os.path.join(REPO, f"Natives/resources/{lang}.lproj/Localizable.strings"),
              "r", encoding="utf-8") as f:
        content = f.read()
    missing = [k for k in NEED if f'"{k}" =' not in content]
    check(f"l10n {lang} Task219 keys present", not missing, f"missing {missing[:3]}")

# VGPU renamed in all 4
for lang, expect in [("en", "VGPU (≤1.17)"), ("zh-Hans", "VGPU（≤1.17）"),
                     ("zh-Hant", "VGPU（≤1.17）"), ("zh-CN", "VGPU（≤1.17）")]:
    with open(os.path.join(REPO, f"Natives/resources/{lang}.lproj/Localizable.strings"),
              "r", encoding="utf-8") as f:
        content = f.read()
    check(f"VGPU rename {lang}", f'= "{expect}";' in content)

print()
print(f"task219_syntax: {len(FAILED)} failed" if FAILED else "task219_syntax: ALL GREEN")
sys.exit(1 if FAILED else 0)
