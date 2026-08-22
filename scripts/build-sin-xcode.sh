#!/bin/bash
# build-sin-xcode.sh — compila SFCast en una maquina que NO tiene Xcode.
#
# POR QUE EXISTE: `swift build` (SPM) se cae sin Xcode con
#   xcrun: error: unable to lookup item 'PlatformPath'
# y sin SPM no se resuelven las dependencias. Pero `swiftc` directo si compila
# SwiftUI, y la dependencia ya esta descargada en .build/checkouts.
#
# El truco son dos piezas:
#   1. KeyboardShortcuts se compila aparte como libreria ESTATICA.
#   2. Ese paquete usa `Bundle.module`, que normalmente genera SPM. Aqui se
#      escribe el puente a mano (solo lo usa para localizar textos).
#
# CANDADO DE FIRMA: se firma con el cert local estable "SFlow Dev" — el MISMO
# con el que estaba firmada la app instalada. Cambiar de identidad tirara los
# permisos de Pantalla, Camara y Microfono que Daniel ya concedio.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
IDENTITY="SFlow Dev"
KS=".build/checkouts/KeyboardShortcuts/Sources/KeyboardShortcuts"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "=== SFCast (sin Xcode) ==="

if [ ! -d "$KS" ]; then
    echo "Falta $KS."
    echo "En una maquina con Xcode: swift package resolve"
    exit 1
fi

echo "[1/5] Puente de Bundle.module"
cat > "$TMP/ks_bundle_shim.swift" <<'EOF'
// Lo genera SPM (resource_bundle_accessor). Sin SPM se escribe a mano.
// KeyboardShortcuts lo usa solo para localizar textos.
import Foundation

extension Bundle {
    static let module: Bundle = {
        let nombre = "KeyboardShortcuts_KeyboardShortcuts"
        let candidatos = [Bundle.main.resourceURL, Bundle(for: BundleAncla.self).resourceURL, Bundle.main.bundleURL]
        for base in candidatos {
            if let u = base?.appendingPathComponent(nombre + ".bundle"), let b = Bundle(url: u) { return b }
        }
        return Bundle.main
    }()
}

private final class BundleAncla {}
EOF

echo "[2/5] KeyboardShortcuts (estatico)"
swiftc -O -emit-module -static -emit-library -module-name KeyboardShortcuts \
    -emit-module-path "$TMP/KeyboardShortcuts.swiftmodule" \
    -o "$TMP/libKeyboardShortcuts.a" \
    $(find "$KS" -name "*.swift") "$TMP/ks_bundle_shim.swift"

echo "[3/5] SFCast"
mkdir -p dist
swiftc -O -I "$TMP" -L "$TMP" -lKeyboardShortcuts \
    $(find Sources -name "*.swift") -o dist/SFCast-bin

echo "[4/5] Bundle"
APP="$ROOT/dist/SFCast.app"
rm -rf "$APP"
# Se parte de la app instalada para conservar Info.plist e icono.
if [ -d /Applications/SFCast.app ]; then
    cp -R /Applications/SFCast.app "$APP"
else
    echo "No hay /Applications/SFCast.app de referencia; haz un build con Xcode primero."
    exit 1
fi
cp dist/SFCast-bin "$APP/Contents/MacOS/SFCast"
rm -f dist/SFCast-bin
rm -rf "$APP/Contents/_CodeSignature"

echo "[5/5] Firma"
if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    echo "Falta el cert '$IDENTITY' (crealo con sflow-next/scripts/make-cert.sh)"
    exit 1
fi
perl -e 'alarm 120; exec @ARGV' codesign --force --deep --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"

echo ""
echo "  Listo: $APP"
echo "  Instalar:  rm -rf /Applications/SFCast.app && cp -R $APP /Applications/"
echo "  ⚠ Haz backup antes: los permisos de Pantalla/Camara son de esta app."
