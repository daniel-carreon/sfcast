# SFCast — Runbook (el Loom soberano de SaaS Factory)

> App macOS nativa (Swift) + pipeline en el VPS. Grabas pantalla con burbuja de
> cámara, al dar stop el link YA está en tu portapapeles, y el VPS genera
> transcript español + título + resumen + capítulos + viewer web solo.
> $0/mes (Loom Business costaba $18-24/user/mes).

## Instalar / actualizar (Mac)

```bash
cd software/sfcast
./scripts/build-app.sh                    # compila + firma "SFlow Dev" → dist/SFCast.app
cp -R dist/SFCast.app /Applications/      # instalar (Spotlight/Launchpad: "SFCast")
open /Applications/SFCast.app             # abre el HUB (panel de control estilo SFlow)
```

La app vive en **/Applications** con su icono propio (anillo mostaza): se abre
desde Spotlight/Launchpad como cualquier app, sin depender de nadie. Con el hub
abierto aparece en el Dock y Cmd+Tab; al cerrarlo queda solo el ⏺ del menu bar.
Salir: Cmd+Q, el botón "Salir de SFCast" del hub, o el menú ⏺.

**Permisos one-time (v1.3, broker serializado):** al abrir la app pide cámara y
micrófono EN SERIE (un solo `requestAccess` por tipo, jamás en ráfaga — la ráfaga
atascaba tccd, ver DECISIONS v1.3). El estado vive en el hub → Inicio → tarjeta
"Permisos", con el botón grande **"Activar cámara y micrófono"** (pídelo por gesto:
es lo más confiable para que el diálogo pinte) y "Reparar" (resetea + re-pide). La
pantalla se pide al primer Grabar. Da "Permitir" en los DOS diálogos (si tienes dos
monitores, míralos ambos).

> **Si NINGÚN diálogo aparece ni con el botón:** la cola de permisos de macOS (tccd)
> quedó atascada — en macOS 26 no se puede reiniciar tccd con SIP activo. **Reinicia
> la Mac UNA vez** y al reabrir SFCast los diálogos salen solos. Es cosa de macOS, no
> de SFCast; el broker ya no inunda tccd, así que no se vuelve a atascar en uso normal.

Tras un UPDATE de la app, macOS 26 re-pide SOLO el de pantalla (1 toggle; el cert
estable evita revocar cámara/mic).

## Grabar (uso diario)

- **Hub → "Grabar pantalla"**, **⌘⇧L**, o menú ⏺: countdown 3s → grabando.
- **Burbuja de cámara**: arrástrala a donde quieras · hover = chips S·M·L·⛶ ·
  doble clic = ciclar tamaño · clic derecho = tamaños y glow (ámbar/morado/nada).
  Se queda GRABADA en el video tal como la ves (burn-in, decisión de diseño).
- **Panel inferior (pill)**: punto rojo pulsante + timer · ⏸ pausa/reanuda ·
  **Detener** (mostaza) · ✕ cancelar. Arrastrable. NO sale en el video.
- **Al detener**: el link queda EN EL PORTAPAPELES al instante Y se abre el
  navegador en la página del video ("Procesando…" que se convierte sola en el
  viewer: ~1-3 min para un video de 5 min).
- Otros modos en el menú ⏺: **Grabar ventana** (una app específica, sin
  burbuja) y **Grabar solo cámara** (talking head).
- **Historial**: hub → Historial (o menú ⏺, últimas 8, clic = copiar link).
- Cámara/mic se eligen en hub → Ajustes (cambiar la cámara con la burbuja en
  pantalla la cambia EN VIVO).

## Selftest del motor (headless)

```bash
/Applications/SFCast.app/Contents/MacOS/SFCast --selftest 4
# SELFTEST_OK bytes=NNN → SCStream+SCRecordingOutput graban de verdad
# Requiere que el permiso de pantalla del build ACTUAL ya esté aprobado
# (macOS 26 lo liga al cdhash: tras un rebuild hay que re-aprobar 1 vez).
```

## URLs

| Qué | URL |
|---|---|
| Video | `https://livekit.saasfactory.so/v/{id}/` |
| Embed (iframe) | `https://livekit.saasfactory.so/embed/{id}/` |
| Biblioteca privada | `https://livekit.saasfactory.so/biblioteca/` (user `daniel`, password en `~/Library/Application Support/SFCast/biblioteca-access.txt`) |

**Embed en la comunidad/about:** botón "Copiar embed" en el viewer → pegar el
`<iframe>` en cualquier lección HTML de SFC o página externa.

## Operar via Levy (AI-first — la UI es espejo)

Los videos viven en el VPS en `/opt/sfcast/www/media/{id}/` (video.mp4,
thumb.jpg, data.json con transcript). Dile a Levy:

- *"lista mis videos de SFCast"* → lee `/opt/sfcast/www/library.json`
- *"borra el video X"* → borra `www/media/{id}`, `www/v/{id}`, `www/embed/{id}` y regenera biblioteca (reinicia el worker o toca `rebuild_library`)
- *"renómbralo a …"* → edita `titulo` en data.json + regenera HTML (worker tiene las funciones)
- *"recórtale los primeros N segundos"* → ffmpeg stream-copy sobre video.mp4 + regenerar thumb/transcript si hace falta

## Migrar a videos.saasfactory.so (5 min, cuando Daniel quiera)

1. Namecheap → saasfactory.so → DNS → **A record**: `videos` → `187.77.22.235`.
2. VPS: duplicar el bloque SFCast del Caddyfile en un site `videos.saasfactory.so { ... }` (mismo root; Caddy emite TLS solo).
3. `/opt/sfcast/pipeline/.env` → `SFCAST_BASE_URL=https://videos.saasfactory.so` + `systemctl restart sfcast-pipeline`.
4. Mac: `~/Library/Application Support/SFCast/settings.json` → `baseURL` nuevo.
5. Los videos viejos siguen sirviendo en ambos dominios (mismo root).

## Monitoreo / recuperación

| Síntoma | Qué hacer |
|---|---|
| ¿Pipeline vivo? | `curl -s https://livekit.saasfactory.so/api/cast/health` |
| Video no aparece tras subir | `ssh hermes-vps 'tail -50 /var/log/sfcast-pipeline.log'` — sesiones fallidas quedan en `/opt/sfcast/incoming/{id}/` con archivo `FAILED`; borrar FAILED y `touch UPLOAD_DONE` para reintentar |
| Upload falló en la Mac | el video queda en `~/Movies/SFCast/{id}/`; re-subir: `rsync -az ~/Movies/SFCast/{id}/ hermes-vps:/opt/sfcast/incoming/{id}/ && ssh hermes-vps touch /opt/sfcast/incoming/{id}/UPLOAD_DONE` |
| Reiniciar worker | `ssh hermes-vps systemctl restart sfcast-pipeline` |
| Validación completa | `./scripts/validate.sh` (5 checks, GREEN esperado) |
| App no graba pantalla | System Settings → Privacidad → Grabación de pantalla → SFCast ON (y relanzar app) |
| Disco Mac <10GB | ScreenCaptureKit puede cortar grabaciones (-3821). Liberar disco |

## Primer uso real de Daniel (los clics one-time)

Al abrir SFCast y grabar por primera vez macOS pedirá, UNA vez: (1) re-confirmar
**Grabación de pantalla** (toggle en Settings), (2) **Cámara** → Permitir (la
burbuja pasa de placeholder negro a tu cara), (3) **Micrófono** → Permitir.
Tras otorgar el mic: poner `"micEnabled": true` en
`~/Library/Application Support/SFCast/settings.json` (quedó en `false` porque
sin el permiso otorgado la grabación se colgaba). El audio de SISTEMA ya graba.

## Límites conocidos (v1, decisiones honestas)

- Burbuja quemada = no editable post (a cambio: link instantáneo).
- Modo ventana = sin burbuja (la burbuja vive en el display, no en la ventana).
- Grabación en pausa NO sobrevive reinicio de la app.
- El unit de Caddy puede mostrar estado "reloading" cosmético (la config nueva
  SÍ está aplicada vía admin API); `systemctl restart caddy` lo limpia cuando
  no haya clases en vivo.
