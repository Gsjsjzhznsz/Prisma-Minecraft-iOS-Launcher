#!/usr/bin/env python3
"""verify_task231.py -- Task 231 (Task230 build "opens and instantly crashes" root-cause fix) gates.
Root cause: the Task230 sprint dead-button migration in init_setupCustomControls used a
RECURSIVE block literal without __block -- non-__block auto vars are value-snapshotted at
literal-evaluation time, when ame230_walk is still nil (ARC zero-init) -> first recursion
reads nil->invoke = EXC_BAD_ACCESS (hardware fault, @try cannot catch) -> trace-less
launch kill. Second defect: options:0 JSON parse yields immutable __NSDictionaryI, so
setValue:forKey: would throw NSInvalidArgumentException (swallowed by @catch) and the
migration could never take effect even without the crash. Each check below asserts a
byte-level anchor (display-layer character-eating defense: pure substring membership)."""
import os, sys, re, glob

BASE = "/home/z/my-project/Amethyst-iOS-MyRemastered"
passed, failed = 0, []

def check(name, path, needle):
    global passed
    p = os.path.join(BASE, path)
    try:
        src = open(p, encoding="utf-8", errors="replace").read()
    except FileNotFoundError:
        failed.append(f"{name}: FILE MISSING {path}")
        return
    if needle in src:
        passed += 1
    else:
        failed.append(f"{name}: anchor missing in {path}")

def check_absent(name, path, needle):
    global passed
    p = os.path.join(BASE, path)
    src = open(p, encoding="utf-8", errors="replace").read()
    if needle not in src:
        passed += 1
    else:
        failed.append(f"{name}: forbidden pattern STILL PRESENT in {path}")

# --- A. main.m: the two defect fixes ----------------------------------------
check("231-A1 recursive block __block", "Natives/main.m",
      "__block void (^ame230_walk)(id) = ^(id node) {")
check("231-A2 mutable containers parse", "Natives/main.m",
      "options:NSJSONReadingMutableContainers")
check_absent("231-A3 old bare options:0 gone from migration parse", "Natives/main.m",
      "JSONObjectWithData:ame230_data options:0")
check("231-A4 root-cause comment", "Natives/main.m",
      "EXC_BAD_ACCESS")
check("231-A5 success anchor intact", "Natives/main.m",
      'NSLog(@"[Pre-init] Task230: sprint dead-button migrated to Left Control 341 in %@", ame230_fn);')
check("231-A6 exception anchor intact", "Natives/main.m",
      'NSLog(@"[Pre-init] Task230: layout migration exception (%@)", ame230_e);')
check("231-A7 try/catch still wraps migration", "Natives/main.m",
      "} @catch (NSException *ame230_e) {")
check("231-A8 sprint keycode bind intact", "Natives/main.m",
      "ame230_new[0] = @341;")
check("231-A9 guard: dead-button condition intact", "Natives/main.m",
      '[ame230_nm containsString:@"\u5e38\u7528"]')

# --- B. DownloadViewController: same-class unexploded mine ------------------
check("231-B1 attemptDownload __block", "Natives/DownloadViewController.m",
      "__block void (^attemptDownload)(void) = ^{")
check_absent("231-B2 bare declaration gone", "Natives/DownloadViewController.m",
      "\n    void (^attemptDownload)(void) = ^{")

# --- C. absence checks implemented above via check_absent -------------------
def check_absent(name, path, needle):
    global passed
    p = os.path.join(BASE, path)
    src = open(p, encoding="utf-8", errors="replace").read()
    if needle not in src:
        passed += 1
    else:
        failed.append(f"{name}: forbidden pattern STILL PRESENT in {path}")

# --- D. fleet-wide recursive-block scan (the audit that should have existed) --
scan_path = os.path.join(BASE, "scripts", "task231_selfref_block_scan.py")
bad = []
if os.path.exists(scan_path):
    import subprocess
    r = subprocess.run([sys.executable, scan_path], capture_output=True, text=True,
                       cwd=os.path.join(BASE, "Natives"))
    for line in r.stdout.splitlines():
        if line.startswith("***"):
            bad.append(line)
    if "total real self-referencing blocks: 5" in r.stdout and not bad:
        passed += 1
    else:
        failed.append(f"231-D fleet scan: expected 5 all-OK, got offenders: {bad or 'count mismatch'}")
else:
    failed.append("231-D: scan script missing")

# --- E. authoritative bracket audit (task225, calibrated tool -- do not
#     hand-roll a cruder stripper; task225 already knows about #pragma lines) ----
import subprocess
r = subprocess.run([sys.executable, os.path.join(BASE, "scripts", "task225_bracket_audit.py")],
                   capture_output=True, text=True, cwd=BASE)
for target in ["Natives/main.m", "Natives/DownloadViewController.m"]:
    hit = [l for l in r.stdout.splitlines() if target in l]
    if hit and hit[0].startswith("[OK "):
        passed += 1
    else:
        failed.append(f"231-E {target}: task225 not OK -> {hit}")

print(f"verify_task231: {passed} passed, {len(failed)} failed")
for f in failed:
    print(f"  FAIL: {f}")
sys.exit(1 if failed else 0)
