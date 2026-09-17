#!/bin/bash
# Install a complete, verified bundle without overwriting a running process.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
case "${1:-}" in
  '') bash "$ROOT/scripts/build-app.sh" ;;
  --skip-build) ;;
  *) echo 'usage: install-app.sh [--skip-build]'; exit 2 ;;
esac
APP="$ROOT/dist/SFCast.app"
DEST=/Applications/SFCast.app
STAMP="$(date +%Y%m%d-%H%M%S)-$$"
STAGE="/Applications/.SFCast-stage-$STAMP.app"
BACKUP="$HOME/Library/Application Support/SFCast/installation-backups/$STAMP.app"
check_idle() {
  if [ -e "$HOME/.sfcast/grabando" ]; then
    echo 'Recording active: installation deferred.'; exit 3
  fi
}
check_idle
codesign --verify --strict "$APP"
ditto "$APP" "$STAGE"
codesign --verify --strict "$STAGE"
check_idle
if pgrep -x SFCast >/dev/null; then
  osascript -e 'tell application id "so.saasfactory.sfcast" to quit'
  for i in {1..30}; do
    pgrep -x SFCast >/dev/null || break
    sleep 1
  done
  if pgrep -x SFCast >/dev/null; then
    echo 'App did not quit; installed bundle untouched.'; exit 4
  fi
fi
check_idle
mkdir -p "$(dirname "$BACKUP")"
HAD_PREVIOUS=false
if [ -d "$DEST" ]; then mv "$DEST" "$BACKUP"; HAD_PREVIOUS=true; fi
restore() {
  if [ -d "$DEST" ]; then mv "$DEST" "/Applications/.SFCast-failed-$STAMP.app"; fi
  if $HAD_PREVIOUS; then mv "$BACKUP" "$DEST"; open -g "$DEST"; fi
}
if ! mv "$STAGE" "$DEST"; then restore; exit 1; fi
if ! codesign --verify --strict "$DEST"; then restore; exit 1; fi
if ! open -g "$DEST"; then restore; exit 1; fi
echo "Installed $DEST; previous version: $BACKUP"
