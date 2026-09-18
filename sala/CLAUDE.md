# SFStudio — plataforma de video de la casa (familia sf*)

## Contrato vigente · 17 septiembre 2026

La UI canónica vive en `sfcast/sala/web`. No desarrollar copias dentro de las skills. `sfreview <proyecto>` detecta `project.json` y delega al puente Python de la skill de edición, sirviendo esta misma UI. `timeline.json` y galería conservan compatibilidad con el servidor Node histórico. `SFSTUDIO_WEB` permite una ruta explícita; `ARTIFICIAL_BRAIN_ROOT` localiza la skill desde el CLI.

El criterio creativo y el grafo E2E viven en la skill `edicion-de-video`: abrir `references/direccion-creativa.md`, `references/estandar.md` y `references/instagram-aprendizajes.md`. No congelar aquí decisiones de herramientas o convertir escenas acabadas en plantillas. SFStudio es sala y soporte de composición; la dirección exige alternativas originales según el video. Hyperframes, Clapper, código 3D o After Effects son mecanismos posibles sujetos al contrato vigente.

## Stack

Node ≥20 ESM sin build step · Playwright (chromium) solo para sfrender y tests · ffmpeg del
sistema (≥7; validado con 8.1) · Python 3 solo el adapter. Vanilla JS en la sala (cero deps de UI).

## Comandos

```bash
npm test                                                  # EL comando de validación (9 checks, incluye humos Playwright)
node bin/sfrender.js <card-dir> -o out.mp4|out.webm|out.mov [--format mp4|webm|prores] [--fps N]
python3 adapter/placed2timeline.py <proyecto>/design      # placed_events.json → sfreview_project/
node bin/sfreview.js <project-dir> --port 3010            # la sala (background siempre; ⌘Y = panel publish · ⌘⌥G = galería)
node bin/sfreview.js --gallery --port 3010                 # SOLO la galería de lanzamientos (sin proyecto abierto)
node bin/sfstudio-apply.js <fixes.json> <master.mp4> [--dry-run] [-o out.mp4]
node bin/sfpublish.js <proyecto> <etapa>                  # etapa 2: init|metadata|link|mentions|thumbs|checklist|schedule|post|launch|watch|upload|connect|status
```

## Invariantes (romperlos = romper la fábrica)

1. **Contrato de cards** (lo escriben los generadores de la skill, NO se cambia aquí):
   `<div id="root" data-composition-id data-start data-duration data-width data-height>` + assets
   RELATIVOS DENTRO del card dir + UNA `gsap.timeline({paused:true})` en `window.__timelines[id]`.
   Animación fuera de esa timeline NO se congela en el render.
2. **timeline.json**: `{name,width,height,fps,duration,base{src},audio{src},items[{id,type,src,
   start,dur,track,fit,muted,alpha}]}` · tracks 1=clips(cover) 2=alpha(contain) 3=caps(stretch).
   Cero hardcode de aspecto: TODO sale de estos campos (16:9 y 9:16 probados).
3. **fixes.json**: `{video, exported_at, trims[{start,end}], markers[{t,nota}], splits[],
   item_edits?[{index,id,start?,dur?,offset?,removed?}], item_adds?[{from,id,start,dur,offset?}]}`
   — es el contrato del loop AI-first (sala → fábrica). `sfstudio-apply` consume SOLO los trims
   del base; `item_edits` (mover/trim/eliminar overlays A MANO en la sala) e `item_adds` (piezas
   nuevas nacidas de partir un asset con S; `from` = índice del item base cuyo media clonan) los
   consume la FÁBRICA: re-colocar los overlays con esos valores antes de imprimir el máster.
   `offset` = in-point del media (trim del borde izquierdo de un overlay de video, o pieza derecha
   de un split). `index`/`from` apuntan a `items[]` del timeline.json abierto; `id` es sanity-check
   (la sala poda ediciones stale si el timeline se regeneró).
4. **WebM alpha**: `libvpx-vp9 -pix_fmt yuva420p -auto-alt-ref 0`, UNA pasada continua (el alpha
   driftea en chunks). VP9 no tiene HW encode en Apple Silicon: paralelizar POR CARD.
5. **Determinismo sfrender**: seek de la timeline pausada + screenshot plano (beginFrame ya no
   existe en Chromium ≥147) + `--force-color-profile=srgb` + fonts.ready + warmup.
6. **Preview y fuentes separadas:** con `project.json`, un video compuesto con audio multiplexado posee el reloj nativo de reproducción. `project.json` conserva cámara, pantalla, cortes, gráficos y sonido editables. La caché por segmento reutiliza lo que no cambió; un recorte puede necesitar codificar el segmento afectado y remultiplexar la película, nunca confundir esto con modificar los originales. Mientras prepara, play permanece bloqueado para no combinar revisión nueva y audio viejo. Export y preview derivan del mismo proyecto. En `timeline.json` histórico se mantiene reproducción raw y saltos en vivo.
7. A-roll al fondo con onda de voz integrada por defecto; separación visual por clic derecho. Pantalla sincronizada como pista propia. SFX y música visibles. No ocultar el recurso principal ni convertir todos los eventos en una única barra.
8. Círculo: preservar altura útil completa, no hacer zoom excesivo en la cabeza. Para 1920×1080, crop cuadrado 1080×1080 con Y=0 y X medido. Burbuja 1:1 sin deformar. La geometría se comprueba en la grabación concreta.

## Gotchas pagados (no re-pagar)

- `waitForFunction` cuyo predicado devuelve la timeline GSAP (objeto circular) = cuelgue infinito
  → devolver SIEMPRE bool.
- polling `'raf'` en headless ocioso se cuelga (sin frames no hay rAF) → polling por intervalo, y
  settles de rAF siempre con timeout de escape.
- CSS `display:flex` le gana al atributo `hidden` → `[hidden]{display:none!important}`.
- Cerrar un input flotante sin `blur()` deja el foco en el elemento oculto y mata el teclado global.
- Base sin `+faststart` no seekea en browser; GOP corto (`-g 30`) para scrub fino.
- `startsWith` desnudo para confinar rutas = traversal por hermano-prefijo (`root` vs
  `root-evil` + `%2e%2e` crudo): usar `insideRoot()` (frontera con `path.sep`). Sin header
  CORS `*` en el server local. Regresión cubierta en test/server.test.js.
- `sfstudio-apply`: guard duración `fixes.duration` vs máster (>1s → aborta, `--force` salta),
  trims fuera de rango SIEMPRE reportados, máster sin audio soportado (graph solo-video).

## SFPublish (etapa 2: máster aprobado → publicado, 19 jul 2026)

- **AI-first radical:** el panel ⌘Y de la sala es ESPEJO de `publish.json` (una card por etapa:
  estado + evidencia + comando), CERO forms — las etapas las corre el agente con `sfpublish`.
  `publish.json` vive en la RAÍZ del proyecto; `/api/publish` de la sala busca en projectDir y
  su padre (la sala corre sobre `sfreview_project/`).
- **Lógica pura en `lib/publish.js`** (menciones, gate, slots, slugs, transcript) — todo con
  unit test. El CLI (`bin/sfpublish.js`) solo orquesta red + disco.
- **SYSTEM_PROMPT de metadata = VERBATIM del producto** (`saas-factory-community/.../youtube-
  descriptions/route.ts`), mismo modelo (`google/gemini-3.1-flash-lite-preview`), misma regla de
  slug (`vid-<ytid>` lowercase, constraint `slug_format`).
- **BD del negocio SOLO lectura** salvo insert IDEMPOTENTE en `tracked_links` (mismo shape que el
  admin API). Credenciales: `agent-server/.env` (business-os).
- **Verificar el /go/ contra `www.`**: el apex `saasfactory.so` responde 308 de Vercel SIN cookies;
  el route con cookies (`link_source`+`utm_params`) vive en `www.saasfactory.so` (gotcha pagado).
- **Menciones: 0 falsos positivos > cobertura.** Racha textual ≥4 tokens del título (≥3 contenido,
  ≥2 distintivos). "claude code" suelto jamás matchea; referencias sin título ("el video de 30
  minutos") NO se detectan — limitación honesta, detección semántica = siguiente iteración.
- **Upload por Data API reanudable:** `sfpublish <proyecto> upload --at "YYYY-MM-DD HH:MM"`
  delega en `agent-server/scripts/youtube/upload_api.py` del cerebro canónico. Requiere
  un paquete válido (publish.json canónico, metadata.json como compatibilidad) y máster (default edit/MASTER.mp4, override --file). `--dry-run` no autentica
  ni sube; `--resume` retoma el ID registrado. `--test` se rechaza sin crear videos.
  Sesión durable privada en `.sfstudio/youtube-upload.json`; nunca servirla en la galería.
  Fallos de consulta del canal impiden una nueva subida. Cards/end screens siguen pendientes
  en Studio: la API no los resuelve. `connect` queda como utilidad histórica, no requisito
  de upload. Contrato detallado en la skill, references/publicacion.md.
- `channel-defaults.json` = config repetible del canal (kids NO, idioma es, visibilidad private).

## La GALERÍA DE LANZAMIENTOS (⌘⌥G, 26 jul 2026)

### Contrato ampliado · 18 septiembre 2026

El catálogo reconoce `publish.json`, `project.json` o `timeline.json`; incluye `youtube/proyectos`.
`project-resources.js` reúne referencias read-only y reporta archivos faltantes. `/gallery/resource`
resuelve tokens del inventario, no rutas proporcionadas por el cliente. Los originales declarados
pueden estar en un SSD; las demás descargas quedan dentro del proyecto.

Identidad durable: `node bin/project-history.js init <proyecto>` crea exclusivamente
`.sfstudio/identity.json` de forma idempotente, sin modificar fuentes ni publicación. El UUID
sigue a la carpeta al moverla. IDs históricos `rN/nombre` se aceptan como compatibilidad; los
nuevos enlaces usan `p/UUID`. Duplicar una carpeta no crea automáticamente otro video: un UUID
duplicado se denuncia. Para un derivado, usar `initIdentity` con `parent_id` y `channel` en una
carpeta nueva. Revertir la migración consiste en apartar `.sfstudio`, conservándola como respaldo;
no se alteraron los archivos preexistentes.

Historial: `project-history.js record <proyecto>` recibe JSON por stdin con `summary`, `result`,
`standard_revision` y `evidence` (rutas de reportes locales de hasta 8 MB). Un `passed` requiere
evidencia. Cada ejecución guarda un archivo nuevo; nunca sobrescribe el registro anterior.
La galería calcula invalidación si cambia el proyecto o falta/cambia una evidencia.
Los registros v2 también fijan hashes de los archivos declarados de estándar y motor,
y una firma de tamaño/mtime/ctime de fuentes y medios. Esta firma evita releer gigabytes,
pero no certifica igualdad criptográfica del contenido. `coverage` muestra qué se cubrió;
los registros v1 conservan su alcance histórico limitado. Las plantillas de asset con
`{variant}` deben resolverse antes de registrar una prueba de esa variante.
`matching` significa que coinciden las entradas registradas; no aprueba el arte ni partes
que la prueba no examinó. Los reportes están enlazados en Recursos y en Revisión del recorrido.

Guardado de galería: el navegador envía `publication_revision` del expediente y ambos
servidores delegan en el mismo adapter. Una revisión obsoleta se rechaza. El candado
`.gallery-write.lock` serializa galería, savePublish del CLI y uploader Python.
El CLI conserva una revisión de lo leído y rechaza sobrescribir una versión distinta.
El uploader combina únicamente campos que cambió, preserva cambios ajenos y rechaza
conflictos sobre el mismo campo. La anotación de autocertificación usa el mismo contrato. Esto no cubre scripts externos que escriban JSON directamente. Si un proceso muere dejando ese archivo, inspeccionar procesos y
resguardar el candado antes de retirarlo; nunca borrar un candado con escritor vivo.
Editar el post revoca su aprobación. Ningún PATCH de galería publica ni reprograma videos.

El acceso al editor verifica `sala-handle.json` contra `/api/health`: PID y ruta del proyecto.
Salas antiguas solo verifican PID y se identifican como compatibilidad; un puerto guardado
no constituye evidencia de una sala viva. El lanzador transmite las raíces a ambos servidores.
Los planes `design/plan*.md` y `design/direccion.json` aparecen como recursos de Diseño;
su existencia no implica aprobación.

La fecha cumplida no prueba publicación; se exige observación pública fechada con ID coincidente.
Tener transcript no demuestra corte aprobado. Estas reglas sustituyen las inferencias antiguas.

El catálogo de TODOS los videos del pipeline, no solo el abierto: rejilla con la portada de cada
lanzamiento y, a un clic, el expediente completo (metadata con capítulos, transcript navegable,
miniaturas candidatas y el post de comunidad). `lib/gallery.js` = modelo puro (con unit tests);
`web/gallery.js` = la vista; `bin/sfreview.js` sirve `/api/gallery`.

- **Un proyecto = una carpeta con `publish.json`, `project.json` o `timeline.json`** bajo las RAÍCES (`--roots`,
  `SFSTUDIO_ROOTS`, o los defaults de `defaultRoots()` en `lib/gallery.js`).
  El histórico del canal NO entra: solo lo que pasó por el pipeline.
- **`publish.json` sigue siendo la fuente de verdad.** La galería lo lee y lo escribe (mismo
  `savePublish` atómico que el CLI); no hay modelo paralelo. Los campos que agrega:
  `data.thumbnail.chosen` (la portada) y `data.post_draft.{body,title,source,approved_at,updated_at}`.
- **Atajo `⌘⌥G`, comparado por `e.code === 'KeyG'`**: en macOS ⌥+g produce `©` y un handler por
  `e.key` jamás dispararía (gotcha pagado). No pisa ⌘Y/⌘E/⌘Z ni S/A/D/Q/E/F/M.
- **Sandbox del id:** la identidad estable es `p/UUID`; `r<idxRaíz>/<carpeta>` conserva compatibilidad.
  Ambos se resuelven contra las raíces configuradas; el token nunca permite una ruta arbitraria.
  El `f=` de `/gallery/thumb` también queda confinado al proyecto.
- **Lo único editable de toda la app** son las dos decisiones que exigen criterio humano: cuál
  miniatura es la portada y el texto+aprobación del post. Todo lo demás sigue siendo espejo.

### El borrador del post ya NO vive en la BD del producto (cambio de diseño, 26 jul)

Antes `post --draft` escribía en `posts` con `is_draft=true`. Eso disparó **1,702 notificaciones
push** (el trigger solo chequeaba `is_draft` para el email; el push salía igual). Ahora:

```
sfpublish post --draft   → arma el borrador en publish.json (NADA toca la BD)
galería ⌘⌥G              → Daniel lo edita y lo APRUEBA (aprobar ≠ publicar)
sfpublish watch          → INSERT normal en posts cuando YouTube confirma público (+N min)
```

`watch` exige TRES condiciones: video público + minutos cumplidos + `approved_at`. Editar el texto
después de aprobar REVOCA la aprobación (nadie firma un texto que cambió). `--dry-run` ensaya el
camino completo sin escribir nada (ni el post ni la miniatura al bucket).

## Integración con la fábrica

El manual del agente vive en la skill: `.claude/skills/edicion-de-video/references/sfstudio.md`
(etapa 1) + `references/publicacion.md` (etapa 2, SFPublish) en business-os. Etapa 6 del pipeline
usa SFStudio por default; el fixture de aceptación fue el proyecto real `video-final-5-practica`
(42 items, base 40 min) — también para SFPublish (transcript word-level de 66 min, 80 títulos del
canal, tracked link real verificado).


### Dirección en el recorrido humano

`creative-direction.js` lee design/direccion.json y lo muestra en Diseño sin duplicarlo.
Previsto/descartado describe decisiones; revisión declarada describe un texto del autor,
no evidencia automáticamente vigente. La aprobación artística se muestra por separado.
Archivos ausentes o inválidos dejan decisiones pendientes. El historial y el render deben
probar la revisión concreta antes de afirmar cumplimiento. El método general queda desplegable.

Las comprobaciones creativas de un registro pueden declarar `creative_checks` con `id`,
`method` (structural/visual/perceptual) y `scope`. Exigen reporte; las entradas fijan también
`design/direccion.json` cuando existe. Diseño muestra el reporte, su alcance y si las entradas
siguen coincidiendo. Una comprobación estructural no convierte una revisión visual pendiente
en aprobada. Cambiar dirección, montaje, código o evidencia invalida el registro correspondiente.

`data.youtube.source_file` conserva el recibo seguro del máster de nuevas subidas. La galería
solo lo vincula si su ID coincide con YouTube y declara transporte completado. Ruta, bytes y
hash registrado no equivalen a aprobación artística; cambios de tamaño/ausencia se muestran.
No inferir un máster aprobado por el nombre más reciente ni fabricar recibos históricos.
