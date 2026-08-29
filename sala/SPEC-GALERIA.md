# Galería de Lanzamientos — Spec

## MISION

Hoy la Sala (`sfreview`) abre **un** proyecto: el que le pasas por argumento. Cuando el video sale,
ese proyecto se vuelve invisible y su trabajo (transcript, descripción, miniaturas, post, fecha de
publicación) queda enterrado en una carpeta que nadie vuelve a abrir. Cada video nuevo empieza de
cero y el canal no tiene memoria operativa.

Construye **la Galería**: el catálogo vivo de todos los lanzamientos del canal, dentro del panel de
SFStudio. Se abre con **⌘⌥G** desde cualquier parte de la Sala y muestra, en una rejilla, TODOS los
videos que pasaron por el pipeline: cada uno con su **miniatura selecta como portada**, su estado de
lanzamiento y su ficha completa a un clic.

La ficha de cada video es el expediente entero del lanzamiento, en un solo lugar:

- **Portada**: la miniatura elegida. Si aún no hay elegida, las candidatas en pequeño para elegir ahí
  mismo (esa elección es la que después sube a YouTube y al post de la comunidad).
- **Estado**, legible de un vistazo y con color: editado · programado para tal día y hora · publicado ·
  post pendiente · post publicado.
- **Metadata**: título elegido (y las alternativas descartadas), descripción completa con sus
  capítulos, keywords, y el link `/go/` con su verificación.
- **Transcript** del máster, navegable y buscable, con sus timestamps.
- **Post de comunidad**: el borrador escrito en la voz de Daniel, editable ahí mismo, con su miniatura,
  y el botón que lo **aprueba** (no lo publica: lo deja listo para salir cuando el video se haga
  público).
- **Cuándo sale**: la fecha y hora programadas del video, y a qué hora saldrá el post en consecuencia.

Es la superficie desde la que Daniel opera TODOS sus lanzamientos y desde la que ve, sin abrir nada
más, en qué estado está cada video que ha hecho. AI-first: la galería es el ESPEJO donde mira y
aprueba; el trabajo pesado lo sigue haciendo el agente hablando con él.

## LIBERTAD TECNICA

Tú eliges cómo construirlo dentro de la web existente: estructura de la vista, layout de la rejilla,
cómo modelas el estado, cómo cacheas, cómo navegas entre ficha y rejilla. La web actual es JS vanilla
sin framework (`web/app.js`, `web/model.js`, `web/style.css`) servida por un server propio en
`bin/sfreview.js`; respeta ese espíritu (cero dependencias nuevas pesadas, cero build step) salvo que
tengas una razón fuerte y la expliques. Cualquier detalle de implementación que aparezca aquí es
sugerencia descartable, NO requisito, salvo la sección RESTRICCIONES.

## INVESTIGA ANTES DE CONSTRUIR

1. **Lee `web/app.js` entero** antes de tocarlo. Es 1,846 líneas y ya tiene: la Sala (timeline,
   recortes S/A/D, marcadores M), el panel de publicación (⌘Y) con sus secciones TRANSCRIPT ·
   METADATA · LANZAMIENTO, y el manejador global de teclado. La Galería se suma a eso sin romperlo:
   ⌘Y sigue siendo el panel del proyecto abierto, ⌘E sigue exportando fixes.
2. **Lee `bin/sfreview.js`**: hoy resuelve UN proyecto (`sfreview <project-dir>`) y sirve
   `/api/project`, `/api/fixes`, `/api/transcript`, `/api/thumbs`, `/api/publish`, `/api/waveform`.
   La Galería necesita un endpoint nuevo que **escanee una raíz de proyectos**, no uno solo.
3. **Lee `bin/sfpublish.js` y `SPEC-PUBLISH.md`**: el modelo de datos del lanzamiento ya existe y es
   `publish.json` (`data.metadata`, `data.thumbs`, `data.post_draft`, `data.launch`,
   `data.post_published_at` y las `stages`). La Galería LEE ese modelo; no inventes uno paralelo.
4. Mira 2-3 referencias de galerías de medios que se sientan rápidas y densas sin ser ruidosas
   (bibliotecas de video, catálogos de assets) y decide el layout desde ahí.

## EL MODELO DE DATOS (lo que ya existe, no lo reinventes)

Un lanzamiento = una carpeta con `publish.json`. Las raíces a escanear:

- `~/Developer/business-os/youtube/videos/*/`
- `~/Developer/business-os/agent-server/workspace/generated/*/`

De cada proyecto salen: `publish.json` (metadata, thumbs, post_draft, launch, stages), las miniaturas
en `thumbs/` o `thumbnails/` (mirar ambas, el auto-chain escribe en la segunda), el transcript en
`edit/transcripts/*.json` o los `TRANSCRIPT-*.txt`, y el cuerpo del post en `post-comunidad*.md`.

## EL DRAFT SALE DE LA BASE DE DATOS DEL PRODUCTO

Decisión de Daniel (26 jul 2026): el borrador del post de comunidad **deja de vivir en
`posts.is_draft`** de la BD de SaaS Factory. Ahora vive en el proyecto y se ve/aprueba **solo desde la
Galería**. La comunidad no muestra nada hasta que el post se publica de verdad.

Consecuencias que tienes que implementar:

- El borrador se guarda en el proyecto (junto a `publish.json`), no en la BD del producto.
- La Galería permite **editar** el texto del borrador y **aprobarlo**. Aprobar ≠ publicar: marca que
  está listo para salir cuando el video se haga público.
- La publicación real la sigue disparando `sfpublish watch` (cron `sfpublish-watch` cada 5 min en el
  Mac Mini): cuando YouTube confirma que el video ya es público y pasan los minutos pactados, el post
  se **inserta** en la comunidad. Al ser un INSERT normal (ya no un borrador), el trigger de la
  comunidad notifica correctamente.
- Hay que **migrar el borrador que ya existe** en la BD (post `9ea19d2b-2ab5-4353-8920-3a2808df2342`,
  el del video Opus 5) al proyecto, y borrarlo de `posts` para que no queden dos fuentes.
- ⚠️ Contexto que costó caro: escribir borradores en `posts` disparó 1,702 notificaciones push el
  26 jul. Ya hay guardas en la BD, pero la razón de fondo de esta decisión es que el borrador no tiene
  por qué tocar la BD de producción hasta el momento de publicar.

## LA VOZ DEL POST

El texto del post se escribe SIEMPRE con
`~/Developer/business-os/.claude/skills/arquitectura-marketing/references/voz-daniel.md` (destilada de
151 posts reales; corpus en `youtube/voz/corpus-daniel-posts.md`). Si la Galería ofrece regenerar o
editar el post, esa referencia es la que manda. El cierre con **pregunta binaria** es su firma.

## DEFINICION DE HECHO (evidencia visible en la conversación)

- El server arranca y la Sala sigue funcionando igual que antes (⌘Y abre el panel, ⌘E exporta fixes,
  S/A/D recortan). No hay regresión.
- **⌘⌥G** abre la Galería desde la Sala, y vuelve a la Sala. Screenshot de ambos estados.
- La rejilla muestra los proyectos reales del disco con su portada. Screenshot con al menos el
  proyecto `2026-07-25-opus5-software-de-pago` visible, con su miniatura `OPUS-01-monumento.png` de
  portada y su estado.
- Al abrir esa ficha se ven, con screenshots: la descripción con sus capítulos, el transcript
  navegable, la lista de miniaturas candidatas con la selecta marcada, y el post de comunidad.
- Se puede **editar el post y aprobarlo** desde la ficha; tras recargar la página el cambio sigue ahí
  (screenshot antes/después que demuestre la persistencia).
- Un proyecto SIN lanzamiento (sin `publish.json` completo) aparece con su estado honesto, sin
  romper la vista ni inventar datos.
- El borrador del Opus 5 quedó migrado al proyecto y **ya no está en la tabla `posts`** (pega la
  verificación).
- El output del comando de validación, en verde.
- Reporte de decisiones: qué estructura elegiste, cómo modelaste el estado, qué endpoint agregaste.
- Lista las formas en que podría estar mal o incompleto, y resuélvelas.

## COMANDO DE VALIDACION

```
cd ~/Developer/software/sfstudio && npm test && node --check web/app.js && node --check bin/sfreview.js
```

Córrelo tras cada cambio grande y pega su output en la conversación. Si `npm test` no cubre lo nuevo,
agrega los tests que falten (hay suite en `test/`).

## RESTRICCIONES REALES

- Vive **dentro del panel de SFStudio** (`web/` servido por `sfreview`), no en Arbrain ni en una app
  nueva. Corre local.
- El atajo es **⌘⌥G** y no puede pisar los existentes (⌘Y panel, ⌘E exportar, ⌘Z deshacer, S/A/D/Q/E/F/M).
- Solo entran proyectos del pipeline (los que tienen `publish.json`). El histórico del canal NO.
- `publish.json` es la fuente de verdad del lanzamiento. La Galería lo lee y lo escribe; no crea un
  modelo paralelo.
- **No publicar nada a YouTube ni a la comunidad** durante el desarrollo. El video del Opus 5 está
  privado y sale mañana; no lo toques.
- Nada de credenciales nuevas ni servicios de pago. Las que hacen falta ya están en
  `~/Developer/business-os/agent-server/.env`.
