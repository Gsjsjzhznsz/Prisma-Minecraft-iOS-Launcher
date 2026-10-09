#!/usr/bin/env bash
# Task234 CI foreground chunked polling (house rule: blocks <= 600s).
# Usage: bash scripts/poll_ci_task234.sh <run_id>
set -u
RUN_ID="${1:?usage: poll_ci_task234.sh <run_id>}"
# token 只从 origin URL 提取（会话内已 set-url）——绝不硬编码：
# GitHub push protection 的 secret scanning 会拦截含 PAT 的提交内容
# （Task234 worklog 提交曾因此被拒，GH013）。
TOK="$(git -C "$(dirname "$0")/.." remote get-url origin | sed -n 's|https://[^:]*:\([^@]*\)@.*|\1|p')"
[ -z "$TOK" ] && { echo "ERROR: no token in origin URL (run: git remote set-url origin https://<token>@github.com/OWNER/REPO.git)"; exit 1; }
API="https://api.github.com/repos/Gsjsjzhznsz/Prisma-Minecraft-iOS-Launcher/actions/runs"
for chunk in $(seq 1 12); do
  for i in $(seq 1 18); do
    st="$(curl -s --max-time 20 -H "Authorization: token $TOK" "$API/$RUN_ID" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("status","?"),d.get("conclusion"))' 2>/dev/null || echo '?')"
    case "$st" in
      completed*) echo "RUN $RUN_ID FINAL: $st"; exit 0 ;;
    esac
    sleep 28
  done
  echo "[chunk $chunk] still running: $st ($(date +%H:%M:%S))"
done
echo "TIMEOUT after 12 chunks"; exit 1
