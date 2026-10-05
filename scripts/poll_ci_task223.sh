#!/usr/bin/env bash
# Task223 CI 轮询（家法：run 出现 → 等完成 → 报结论；限流退避）
# 用法: bash /home/z/my-project/Amethyst-iOS-MyRemastered/scripts/poll_ci_task223.sh
REPO="Gsjsjzhznsz/Prisma-Minecraft-iOS-Launcher"
SHA="888112a679c05b7833cbb9da702c8965ca5eda90"
TOKEN="$(git -C /home/z/my-project/Amethyst-iOS-MyRemastered remote get-url origin | sed -n 's#https://\([^@]*\)@.*#\1#p')"
OUT=/tmp/ci223.log
: > "$OUT"
api() {
  curl -s --max-time 30 -H "Authorization: token ${TOKEN}" "https://api.github.com/repos/${REPO}/actions/runs?per_page=10"
}
RUN_ID=""
for i in $(seq 1 40); do
  JSON=$(api)
  RUN_ID=$(echo "$JSON" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    for r in d.get('workflow_runs', []):
        if r['head_sha'].startswith('888112a'):
            print(r['id']); break
except Exception:
    pass
" 2>/dev/null)
  if [ -n "$RUN_ID" ]; then break; fi
  echo "[$i] run not visible yet (or rate-limited), retry in 30s" >> "$OUT"
  sleep 30
done
if [ -z "$RUN_ID" ]; then
  echo "RUN NOT FOUND after retries" >> "$OUT"
  exit 1
fi
echo "RUN_ID=$RUN_ID" >> "$OUT"
for i in $(seq 1 90); do
  STATUS=$(curl -s --max-time 30 -H "Authorization: token ${TOKEN}" \
    "https://api.github.com/repos/${REPO}/actions/runs/${RUN_ID}" | \
    python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('status','?'), d.get('conclusion',''))" 2>/dev/null)
  echo "[$i] $STATUS" >> "$OUT"
  case "$STATUS" in
    completed*) break ;;
  esac
  sleep 30
done
CONCLUSION=$(curl -s --max-time 30 -H "Authorization: token ${TOKEN}" \
  "https://api.github.com/repos/${REPO}/actions/runs/${RUN_ID}" | \
  python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('conclusion','unknown'))" 2>/dev/null)
echo "FINAL: $CONCLUSION" >> "$OUT"
