#!/bin/bash
# build-app.sh — Compila SFCast y ensambla dist/SFCast.app desde SPM (sin xcodeproj).
# Patrón heredado de SFlow v3 (candados de firma incluidos).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "=== SFCast build ==="

echo "[1/4] swift build -c release"
swift build -c release 2>&1 | tail -2

echo "[2/4] Ensamblando bundle"
APP="$ROOT/dist/SFCast.app"
for i in 1 2 3; do
    rm -rf "$ROOT/dist" 2>/dev/null && break || sleep 1
done
if [ -e "$ROOT/dist" ]; then
    echo "ERROR: no se pudo limpiar dist/. Abortando."
    exit 1
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/SFCast "$APP/Contents/MacOS/SFCast"
cp Info.plist "$APP/Contents/Info.plist"
if [ -d ".build/release/SFCast_SFCast.bundle" ]; then
    cp -R ".build/release/SFCast_SFCast.bundle" "$APP/Contents/Resources/"
fi
# Icono de la app (regenerar: swift scripts/make-icon.swift + iconutil, ver assets/)
if [ -f "assets/SFCast.icns" ]; then
    cp assets/SFCast.icns "$APP/Contents/Resources/SFCast.icns"
fi

echo "[3/4] Firmando"
# CANDADO (heredado de SFlow v3): firma SIEMPRE con cert local ESTABLE, JAMÁS
# ad-hoc — ad-hoc cambia el cdhash cada rebuild y TCC revoca Pantalla/Cámara/Mic.
# Reusamos la identidad "SFlow Dev" (misma máquina, mismo keychain, cero
# ceremonia extra). En macOS 15+ ScreenCaptureKit NO funciona con ad-hoc.
IDENTITY="SFlow Dev"
if ! security find-certificate -c "$IDENTITY" ~/Library/Keychains/login.keychain-db >/dev/null 2>&1; then
    echo "   Cert '$IDENTITY' no existe — créalo con software/sflow-next/scripts/make-cert.sh"
    exit 1
fi
# Timeout perl: con la SESIÓN BLOQUEADA codesign se cuelga para siempre (gotcha SFlow 12-jul).
if ! perl -e 'alarm 120; exec @ARGV' codesign --force --deep --sign "$IDENTITY" "$APP"; then
    echo "ERROR: no se pudo firmar. Si tardó 120s: la Mac está BLOQUEADA — desbloquea y reintenta."
    exit 1
fi
codesign --verify --strict "$APP" || { echo "ERROR: firma no verifica"; exit 1; }
echo "   Firmado con '$IDENTITY' (TCC estable entre rebuilds)"

echo "[4/4] Listo"
echo "  App:    $APP"
echo "  Tamaño: $(du -sh "$APP" | cut -f1)"
