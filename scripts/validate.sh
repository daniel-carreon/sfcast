#!/bin/bash
# validate.sh — COMANDO DE VALIDACIÓN CANÓNICO de SFCast (goal contract).
# App Swift + worker Python + rutas web + healthcheck del VPS, en uno.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAIL=0

step() { printf "%-46s" "$1"; }
ok()   { echo "✓"; }
bad()  { echo "✗ $1"; FAIL=1; }

step "[1/5] swift build (app)"
if (cd "$ROOT" && swift build -c release >/dev/null 2>&1); then ok; else bad "no compila"; fi

step "[2/5] py_compile (worker VPS)"
if python3 -m py_compile "$ROOT/infra/sfcast_worker.py" 2>/dev/null; then ok; else bad "sintaxis"; fi

step "[3/5] worker /health (VPS via Caddy)"
H=$(curl -s --max-time 10 https://videos.saasfactory.so/api/cast/health 2>/dev/null)
if echo "$H" | grep -q '"ok": true'; then ok; else bad "$H"; fi

step "[4/5] biblioteca gated (401 sin auth)"
CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 https://videos.saasfactory.so/biblioteca/ 2>/dev/null)
if [ "$CODE" = "401" ]; then ok; else bad "HTTP $CODE"; fi

step "[5/5] healthcheck LiveKit VPS (invariante Meet)"
HC=$(ssh -o ConnectTimeout=10 hermes-vps '/opt/livekit/healthcheck.sh 2>/dev/null | tail -1')
if echo "$HC" | grep -qi "GREEN\|13/13\|OK"; then ok; else bad "$HC"; fi

echo "────────────────────────────────"
if [ "$FAIL" = 0 ]; then echo "VALIDATE: GREEN (5/5)"; else echo "VALIDATE: RED"; exit 1; fi
