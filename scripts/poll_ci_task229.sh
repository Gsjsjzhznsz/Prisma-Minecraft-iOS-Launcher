#!/bin/bash
# Task229 CI poller -- foreground chunked discipline (one call = one chunk <= 9.5min,
# 30s ticks inside; re-invoke until completed). Family law: nohup backgrounds
# get reaped by the sandbox.
TOKEN=$(cat /home/z/my-project/.tok2)
RUN_ID="${1:-37803120057}"
TICKS="${2:-18}"   # 18 x 30s = 9 minutes per chunk

for i in $(seq 1 "$TICKS"); do
  STATUS=$(curl -s --max-time 20 -H "Authorization: token $TOKEN" \
    "https://api.github.com/repos/Gsjsjzhznsz/Prisma-Minecraft-iOS-Launcher/actions/runs/$RUN_ID" \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('status','?'), d.get('conclusion') or '-')" 2>/dev/null)
  echo "[$(date +%H:%M:%S)] tick $i: $STATUS"
  case "$STATUS" in
    completed*) echo "RUN $RUN_ID COMPLETED: $STATUS"; exit 0;;
  esac
  sleep 30
done
echo "CHUNK EXHAUSTED (still $STATUS) -- re-invoke this script for the next chunk"
exit 2
