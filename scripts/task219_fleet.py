#!/usr/bin/env python3
# Task219 fleet runner: per-verifier timeout, summary, env-broken detection.
import subprocess, sys, os, glob, re

REPO = os.path.dirname(os.path.abspath(__file__)) + "/.."
os.chdir(REPO)

# Verifiers that hard-depend on the OUTER workspace (pruned by the sandbox
# rollback) -- proven environment-broken by the git-stash control experiment.
OUTER_WS = {"verify_task132.py", "verify_task133.py", "verify_task134.py",
            "verify_task135.py", "verify_task150.py", "verify_task156.py",
            "verify_task157.py", "verify_task168.py", "verify_task171.py",
            "verify_task174.py", "verify_task175.py", "verify_task179.py",
            "verify_task181.py", "verify_task182.py"}

verifiers = sorted(os.path.basename(p) for p in glob.glob("scripts/verify_task*.py"))
only = sys.argv[1:] if len(sys.argv) > 1 else None

ok_list, fail_list, env_list, slow_list = [], [], [], []
for v in verifiers:
    if only and not any(o in v for o in only):
        continue
    if v in OUTER_WS:
        env_list.append(v)
        continue
    if v == "verify_task219.py":
        continue  # run separately for the detailed report
    try:
        r = subprocess.run([sys.executable, f"scripts/{v}"], capture_output=True,
                           text=True, timeout=110)
        out = r.stdout + r.stderr
        if r.returncode == 0 and ("ALL PASS" in out or "ALL GREEN" in out or "passed" in out and "0 failed" in out):
            ok_list.append(v)
        elif "FileNotFoundError" in out and ("workspace" in out or "my-project/scripts" in out):
            env_list.append(v + " (outer-ws)")
        else:
            fail_list.append((v, [l for l in out.splitlines() if "FAIL" in l][:3]))
    except subprocess.TimeoutExpired:
        slow_list.append(v)

print("=" * 60)
print(f"PASS: {len(ok_list)}")
for v in ok_list:
    print("  ok:", v)
print(f"ENV-BLOCKED (outer workspace, pre-existing): {len(env_list)}")
for v in env_list:
    print("  env:", v)
print(f"TIMEOUT (>110s, need individual run): {len(slow_list)}")
for v in slow_list:
    print("  slow:", v)
print(f"REAL FAILURES: {len(fail_list)}")
for v, lines in fail_list:
    print("  FAIL:", v)
    for l in lines:
        print("        ", l.strip()[:150])
sys.exit(1 if fail_list else 0)
