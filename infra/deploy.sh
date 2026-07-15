#!/bin/bash
# deploy.sh — sube el worker de SFCast al VPS y (re)arranca el servicio.
set -euo pipefail
HOST="${1:-hermes-vps}"
DIR="$(cd "$(dirname "$0")" && pwd)"

scp "$DIR/sfcast_worker.py" "$HOST:/opt/sfcast/pipeline/sfcast_worker.py"
scp "$DIR/sfcast-pipeline.service" "$HOST:/etc/systemd/system/sfcast-pipeline.service"
# restart SIEMPRE: enable --now NO recarga un servicio ya corriendo (gotcha E2E)
ssh "$HOST" 'systemctl daemon-reload && systemctl enable sfcast-pipeline >/dev/null 2>&1; systemctl restart sfcast-pipeline && sleep 2 && systemctl is-active sfcast-pipeline && curl -s 127.0.0.1:9096/health'
echo
echo "deploy OK"
