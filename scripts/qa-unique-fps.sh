#!/usr/bin/env bash
#
# qa-unique-fps.sh — LA VERDAD DE TIERRA sobre el movimiento de una grabación.
#
# Por qué existe (17 ago 2026):
#
#   `CadenceKeeper` EXISTE para forzar 30 fps constantes rellenando los huecos con
#   el último frame compuesto. `achievedFps` MIDE esos 30 fps. Por construcción,
#   ese sensor está cableado a la salida de su propio actuador y no puede reportar
#   la falla — y `--rectest` tampoco alcanza, porque asierta contra el MISMO
#   contador interno (`repeatedFrames`).
#
#   Este script no le pregunta nada a la app. Decodifica el archivo y cuenta
#   cuántos frames tienen contenido DISTINTO del anterior (mpdecimate). Eso es lo
#   que el ojo percibe como fluidez.
#
#   Medido el 15 ago sobre la misma toma, misma cámara, minutos de diferencia:
#     sfcast    (dw0w7tu0rea1)  →  12.8 fps únicos   (el archivo declaraba 29.61)
#     Streamlabs                →  27.3 fps únicos   (100% de frames a 33.33 ms)
#
# Uso:
#   scripts/qa-unique-fps.sh <archivo.mp4|dir-de-sesión> [fps-objetivo] [segundos]
#
#   scripts/qa-unique-fps.sh ~/Movies/SFCast/dw0w7tu0rea1
#   scripts/qa-unique-fps.sh video.mp4 30 120
#
# ⚠️⚠️ LÍMITE DURO: SOLO VALE SOBRE MATERIAL CON MOVIMIENTO REAL.
#
#   Esto mide si el CONTENIDO cambia, y no puede distinguir "el pipeline se cayó"
#   de "no se movió nada frente a la cámara". Verificado en carne propia el 17 ago:
#   corrí el gate sobre dos `--rectest` headless de las 6:33 AM, sin nadie frente a
#   la cámara, y dio 2.46 y 2.95 fps — mientras la app reportaba 27.48 correctos.
#   El gate no estaba delatando a la app: estaba midiendo un estudio vacío.
#
#   ⇒ El sensor AUTORITATIVO del pipeline es `uniqueContentFps` del manifest
#     (= frames compuestos reales / duración, restando el relleno de CadenceKeeper).
#     Ese no se confunde con contenido quieto porque cuenta lo que el compositor
#     PRODUJO, no lo que cambió en la imagen.
#
#   ⇒ Este script es el CONTRA-CHEQUE independiente: sirve para auditar al sensor
#     interno, y solo sobre una toma donde alguien de verdad esté hablando. Si el
#     resultado sale absurdamente bajo (<5 fps), lo más probable es que la escena
#     estuviera quieta — el script lo avisa en vez de cantar victoria.
#
# Salida: QA_UNIQUE_FPS <valor> / QA_TARGET <valor> / QA_PCT <%> / QA_OK|QA_FAIL
#
# ⚠️  LA VARA ES 85%, NO 100% — y eso NO es laxitud, está calibrado con medición.
#
#   `mpdecimate` tira frames cuyo contenido es idéntico al anterior, y en una
#   toma REAL de cabeza parlante siempre hay frames legítimamente idénticos:
#   Daniel se queda quieto entre palabras, hace una pausa, mantiene una pose. O
#   sea que el 100% es INALCANZABLE por contenido, no por rendimiento.
#
#   Anclas medidas el 17 ago sobre la misma toma, misma cámara, minutos aparte:
#     Streamlabs, CFR perfecto (100% de frames a 33.33 ms)  →  91.7%   ← el techo real
#     sfcast degradado (compuso a 15/30 el 94% de la toma)  →  42.1%   ← la falla
#
#   El hueco entre 92 y 42 es tan grande que cualquier vara entre ~70 y ~88 separa
#   bien. 85% deja margen para contenido con más quietud sin dejar pasar una toma
#   a medio movimiento. NO subirla a 95/100 "para ser estrictos": eso reprobaría
#   la referencia buena y el gate se dejaría de leer.
#   (Es la lección propia: el arnés de medición miente antes que el motor.)

set -euo pipefail

TARGET_DEFAULT=30
SAMPLE_DEFAULT=120     # segundos a analizar (decodificar 45 min de HEVC es caro)
SKIP=30                # se salta el arranque: los primeros segundos no son típicos
PASS_PCT=85          # calibrado, no elegido — ver la nota de arriba

ruta="${1:-}"
if [[ -z "$ruta" ]]; then
  /usr/bin/sed -n '3,30p' "$0" | /usr/bin/sed 's/^# \{0,1\}//'
  exit 64
fi

# Acepta el directorio de la sesión: busca el programa, no los raws.
if [[ -d "$ruta" ]]; then
  for cand in "$ruta/seg-001.mp4" "$ruta/"*.mp4; do
    [[ -f "$cand" ]] && { ruta="$cand"; break; }
  done
fi
[[ -f "$ruta" ]] || { echo "no encuentro el archivo: $ruta" >&2; exit 66; }

target="${2:-}"
sample="${3:-$SAMPLE_DEFAULT}"

# El fps pedido sale del manifest si está al lado; si no, del argumento/default.
manifest="$(/usr/bin/dirname "$ruta")/manifest.json"
if [[ -z "$target" && -f "$manifest" ]]; then
  target="$(/usr/bin/python3 -c "
import json,sys
try: print(json.load(open('$manifest')).get('fps') or '')
except Exception: print('')" 2>/dev/null || true)"
fi
target="${target:-$TARGET_DEFAULT}"

command -v ffmpeg  >/dev/null || { echo "falta ffmpeg (brew install ffmpeg)"  >&2; exit 69; }
command -v ffprobe >/dev/null || { echo "falta ffprobe (brew install ffmpeg)" >&2; exit 69; }

dur="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$ruta" 2>/dev/null | /usr/bin/cut -d. -f1)"
dur="${dur:-0}"
# Si el video es corto, se analiza desde el principio y completo.
skip="$SKIP"; (( dur > SKIP + 10 )) || skip=0
(( dur - skip < sample )) && sample=$(( dur - skip ))
(( sample > 0 )) || { echo "el video es demasiado corto para medir" >&2; exit 65; }

echo "── qa-unique-fps ─────────────────────────────────────────"
echo "   archivo : $(/usr/bin/basename "$ruta")"
echo "   ventana : ${sample}s desde t=${skip}s  (de ${dur}s totales)"
echo "   objetivo: ${target} fps"

# Se normaliza a 1280x720 ANTES de mpdecimate: sus umbrales trabajan sobre
# bloques 8x8, así que comparar 1440p contra 1080p sin escalar sesga el conteo.
# Estos parámetros son los mismos con que se midió sfcast contra Streamlabs.
kept="$(ffmpeg -hide_banner -nostdin -ss "$skip" -t "$sample" -i "$ruta" -an \
        -vf "scale=1280:720,mpdecimate=hi=768:lo=320:frac=0.33" -f null - 2>&1 \
        | /usr/bin/grep -oE 'frame= *[0-9]+' | /usr/bin/tail -1 \
        | /usr/bin/grep -oE '[0-9]+' || true)"
[[ -n "$kept" ]] || { echo "ffmpeg no devolvió conteo de frames" >&2; exit 70; }

unique="$(/usr/bin/python3 -c "print(f'{$kept/$sample:.2f}')")"
pct="$(/usr/bin/python3 -c "print(f'{$kept/$sample/$target*100:.1f}')")"

echo
echo "QA_UNIQUE_FPS $unique"
echo "QA_TARGET $target"
echo "QA_PCT $pct"
if /usr/bin/python3 -c "import sys; sys.exit(0 if $pct >= $PASS_PCT else 1)"; then
  echo "QA_OK — el material se mueve a lo que dice el contenedor"
  exit 0
fi
# Un resultado absurdamente bajo casi nunca es el pipeline: es una escena quieta.
# Decirlo aquí evita el falso positivo que yo mismo me tragué el 17 ago.
if /usr/bin/python3 -c "import sys; sys.exit(0 if $unique < 5 else 1)"; then
  echo "QA_INDETERMINADO — ${unique} fps únicos es DEMASIADO bajo para ser solo el pipeline."
  echo "         Lo más probable: en este tramo no se movía nada frente a la cámara"
  echo "         (estudio vacío, toma en pausa, o pantalla estática). Este gate no"
  echo "         distingue eso de un pipeline caído: mídelo sobre material donde"
  echo "         alguien esté HABLANDO, y para el pipeline usa uniqueContentFps"
  echo "         del manifest, que cuenta lo que el compositor produjo."
  exit 2
fi
echo "QA_FAIL — el archivo declara ${target} fps pero se MUEVE a ${unique}"
echo "         (vara: >= ${PASS_PCT}% — la referencia buena medida da ~92%)"
echo "         Si esto sale rojo: cierra y reabre SFCast antes de la toma buena y"
echo "         libera RAM. El compositor se degrada con las horas que lleva abierta"
echo "         (medido: 1.1-2.2 ms recién abierta → 5.1-8.1 ms a los ~3 días)."
exit 1
