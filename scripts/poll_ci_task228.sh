#!/bin/bash
# Task228 CI poll -- foreground, one block per invocation (<= ~9 min, 30s ticks).
# Usage: poll_ci_task228.sh <head_sha> [run_id_hint]
# Exit codes: 0 = a run completed (see output for conclusion), 3 = still
# running/pending after this block, 2 = transient API trouble (retry).
TOK=$(tr -d '[:space:]' < /home/z/my-project/.tok2)
SHA="$1"
REPO="Gsjsjzhznsz/Prisma-Minecraft-iOS-Launcher"

for i in $(seq 1 17); do
  out=$(curl -sS --max-time 20 -H "Authorization: token $TOK" \
    "https://api.github.com/repos/$REPO/actions/runs?head_sha=${SHA}&per_page=3" 2>/dev/null)
  echo "$out" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("api parse error"); sys.exit(2)
runs = d.get("workflow_runs") or []
if not runs:
    print("no run visible yet"); sys.exit(1)
for r in runs[:3]:
    print("run %s | %s | %s | %s | %s" % (r["id"], r["name"], r["status"],
                                          r.get("conclusion"), r["created_at"]))
done = [r for r in runs if r["status"] == "completed"]
sys.exit(0 if done else 1)
'
  rc=$?
  if [ $rc -eq 0 ]; then
    exit 0
  fi
  sleep 30
done
exit 3
