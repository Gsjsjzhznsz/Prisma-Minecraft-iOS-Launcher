#!/usr/bin/env bash
# Task309 CI polling (house rule: blocks <= 600s). Same auth as task235.
# Usage: bash scripts/poll_ci_task309.sh [sha_prefix]
set -u
SHA_PREFIX="${1:-41b9ea09}"
REPO="Gsjsjzhznsz/Prisma-Minecraft-iOS-Launcher"
# token 只从 origin URL 提取（绝不硬编码，GH013 家法）：
TOK="$(git -C "$(dirname "$0")/.." remote get-url origin | sed -n 's|https://\([^@/]*\)@.*|\1|p')"
[ -z "$TOK" ] && { echo "ERROR: no token in origin URL"; exit 1; }

for chunk in $(seq 1 20); do
  R=$(curl -s --max-time 30 -H "Authorization: token ${TOK}" \
    "https://api.github.com/repos/${REPO}/actions/runs?per_page=5")
  ROW=$(echo "$R" | python3 -c "
import json,sys
d=json.load(sys.stdin)
runs=d.get('workflow_runs',[])
hit=[r for r in runs if r['head_sha'].startswith('${SHA_PREFIX}')]
if not hit:
    print('NONE')
else:
    r=hit[0]
    print(f\"{r['id']}|{r['name']}|{r['status']}|{r.get('conclusion')}\")
" 2>/dev/null)
  if [ "$ROW" = "NONE" ] || [ -z "$ROW" ]; then
    echo "[chunk $chunk] no run for ${SHA_PREFIX} yet, sleep 30"
    sleep 30
    continue
  fi
  RUN_ID=$(echo "$ROW" | cut -d'|' -f1)
  NAME=$(echo "$ROW" | cut -d'|' -f2)
  STATUS=$(echo "$ROW" | cut -d'|' -f3)
  CONCL=$(echo "$ROW" | cut -d'|' -f4)
  echo "[chunk $chunk] run=$RUN_ID name=$NAME status=$STATUS conclusion=$CONCL"
  if [ "$STATUS" = "completed" ]; then
    exit $([ "$CONCL" = "success" ] && echo 0 || echo 2)
  fi
  sleep 30
done
echo "TIMEOUT: run not completed in 10 min"
exit 3
