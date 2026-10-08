#!/usr/bin/env python3
"""Task225: house five-state stripper + bracket balance over all modified files.
(House rule: string-first stripping — URLs contain // which line comments would
truncate; see Task223 lesson. States: code / line-comment / block-comment /
single-string / char-literal.)"""
import sys, subprocess

FILES = subprocess.run(
    ["git", "diff", "--name-only", "HEAD"],
    cwd="/home/z/my-project/Amethyst-iOS-MyRemastered",
    capture_output=True, text=True).stdout.split()
FILES = [f for f in FILES if f.endswith((".m", ".h", ".c"))]
if not FILES:
    print("no modified source files")
    sys.exit(0)

def strip(src):
    # Task230 fix: #pragma lines are preprocessor directives, not code --
    # "#pragma mark - 1) xxx" section titles carry literal ')' that poisoned
    # the count (sdl3_hook.m showed a stable -6 phantom imbalance at HEAD
    # that could never surface before because the file was never modified).
    src = "\n".join("" if ln.lstrip().startswith("#pragma") else ln
                     for ln in src.split("\n"))
    out = []
    i, n = 0, len(src)
    STATE_CODE, STATE_LINE, STATE_BLOCK, STATE_STR, STATE_CHAR = range(5)
    st = STATE_CODE
    while i < n:
        c = src[i]
        nxt = src[i+1] if i + 1 < n else ""
        if st == STATE_CODE:
            if c == "/" and nxt == "/":
                st = STATE_LINE; i += 2; continue
            if c == "/" and nxt == "*":
                st = STATE_BLOCK; i += 2; continue
            if c == '"':
                st = STATE_STR; i += 1; continue
            if c == "'":
                st = STATE_CHAR; i += 1; continue
            out.append(c); i += 1
        elif st == STATE_LINE:
            if c == "\n":
                st = STATE_CODE; out.append(c)
            i += 1
        elif st == STATE_BLOCK:
            if c == "*" and nxt == "/":
                st = STATE_CODE; i += 2; continue
            if c == "\n":
                out.append(c)
            i += 1
        elif st == STATE_STR:
            if c == "\\":
                i += 2; continue
            if c == '"':
                st = STATE_CODE
            i += 1
        else:  # CHAR
            if c == "\\":
                i += 2; continue
            if c == "'":
                st = STATE_CODE
            i += 1
    return "".join(out)

def counts(code):
    # square brackets and braces and parens
    return (code.count("["), code.count("]"),
            code.count("{"), code.count("}"),
            code.count("("), code.count(")"))

fail = 0
for f in FILES:
    try:
        src = open("/home/z/my-project/Amethyst-iOS-MyRemastered/" + f, encoding="utf-8").read()
    except FileNotFoundError:
        continue
    code = strip(src)
    ob, cb, oc, cc, op, cp = counts(code)
    ok = (ob == cb) and (oc == cc) and (op == cp)
    # git-pinned HEAD comparison for delta reasoning
    head = subprocess.run(["git", "-C", "/home/z/my-project/Amethyst-iOS-MyRemastered",
                           "show", "HEAD:" + f], capture_output=True, text=True)
    if head.returncode == 0:
        hob, hcb, hoc, hcc, hop, hcp = counts(strip(head.stdout))
        delta = (ob-hob, cb-hcb, oc-hoc, cc-hcc, op-hop, cp-hcp)
    else:
        delta = None
    status = "OK " if ok else "FAIL"
    if not ok:
        fail += 1
    print(f"[{status}] {f}: []={ob}/{cb} {{}}={oc}/{cc} ()={op}/{cp}"
          + (f" delta={delta}" if delta else ""))

sys.exit(1 if fail else 0)
