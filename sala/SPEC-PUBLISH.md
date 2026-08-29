# SFPublish — Spec (build nocturno one-shot, 19 jul 2026)

> Segunda etapa de la línea de producción: del MÁSTER APROBADO al video PUBLICADO y midiendo.
> Decisión de Daniel: panel de control post-edición con ⌘Y en la sala, **AI-first radical**
> ("la UI es espejo, no cabina"): el panel MUESTRA el avance; las etapas las EJECUTA el agente.
> Todo sobre `main`. El producto SFC es INTOCABLE (cero código, cero deploys).

## MISIÓN

Extender SFStudio (`~/Developer/software/sfstudio`) con la etapa de publicación: un modelo de
estado `publish.json` por proyecto + un panel espejo (⌘Y en sfreview) + un CLI `sfpublish` con las
etapas ejecutables + el flujo de subida agéntica a YouTube Studio por navegador. La cadena que
cierra: máster → transcript → descripción+link limpio → tarjetas por menciones → checklist →
upload → publicado (→ atribución, etapa 3).

## CONTEXTO OBLIGATORIO (leer antes de escribir código)

- `SPEC.md` de este repo + `CLAUDE.md` del repo (invariantes) + skill `edicion-de-video`:
  `SKILL.md` + `references/sfstudio.md`.
- **Código de REFERENCIA del producto (solo lectura, NO editar):**
  - `saas-factory-community/src/app/api/admin/youtube-descriptions/route.ts` — la Description
    Machine: SU `SYSTEM_PROMPT` se REUSA VERBATIM (copiarlo citando la fuente) y su lógica de
    slug (lowercase, constraint `slug_format`) y de crear/reusar `tracked_links`.
  - `saas-factory-community/src/app/go/[slug]/route.ts` — el redirect limpio + cookies de
    atribución (`link_source`, `utm_params`) + log en `link_clicks`.
- **BD del negocio** (Supabase `pzguhreaiadchdxdvauz`, MCP `supabase-saas-factory`): tablas
  `tracked_links`, `link_clicks`, `youtube_videos`. SOLO lectura, con UNA excepción: insert
  IDEMPOTENTE en `tracked_links` (mismo shape que el admin API; si el slug existe, reusar).
- **Credenciales**: `OPENROUTER_API_KEY` en `agent-server/.env` (para la generación de metadata).
- **Fixture real**: `agent-server/workspace/generated/video-final-5-practica/` — usar su
  transcript real (buscar el transcript del corte en `edit/`/`design/`; si no hay uno utilizable,
  re-transcribir `edit/clean30f7.mp4` con MLX Whisper local: `~/.whisper-mlx-venv`).
- Peak hours reales del canal (para `schedule`): 11AM, 4-5PM, 9PM México; lunes más activo.

## COMPONENTE 1 — `publish.json` + panel ⌘Y (el espejo)

- **`publish.json`** en el dir del proyecto: `{video: {slug, titulo}, stages: {metadata, link,
  mentions, thumbnail, checklist, schedule, upload, published}: cada una {status:
  pending|running|done|error, evidence, updated_at}, log: []}`. Lo escriben los comandos del CLI;
  el panel SOLO lo lee.
- **Panel en sfreview**: `⌘Y` (o `Y`) togglea un overlay sobre la sala — pipeline de cards por
  etapa: estado (color), evidencia resumida (ej. "descripción 4,812 chars · /go/kimi-k3 ✓ 307"),
  timestamp, y el COMANDO exacto que el agente corre para esa etapa (visible para copiar, no un
  form). Poll de publish.json cada 2s. Marca de la casa, 0 errores de consola.
- **Cero cabina**: ningún input de texto/form en el panel. Si una etapa necesita decisión humana
  (elegir título de los 3, aprobar tarjetas), el panel lo señala y la decisión se toma
  CONVERSANDO con Levy (o editando publish.json vía el CLI), no clickeando.

## COMPONENTE 2 — CLI `sfpublish` (las etapas ejecutables)

`bin/sfpublish.js <proyecto> <etapa>` — cada etapa escribe su resultado + estado en publish.json:

- **`metadata`**: lee el transcript → OpenRouter con el SYSTEM_PROMPT del producto (verbatim) →
  `{description, titles[3], keywords, summary, thumbnail_suggestion}` → crea/reusa el tracked
  link `/go/<slug>` en Supabase (idempotente) → **verifica en vivo**: `curl -I
  https://saasfactory.so/go/<slug>` debe dar redirect + `Set-Cookie` de atribución. Guarda todo.
- **`mentions`**: transcript vs títulos de `youtube_videos` (fuzzy: normalizar, n-gramas de
  título, umbral conservador — 0 falsos positivos > cobertura) → plan de tarjetas
  `[{t, video_id, titulo, frase_detectada}]` + candidato a pantalla final. Guarda el plan.
- **`checklist`**: gate de publicación — título ≤60 chars, descripción con `/go/` en las
  primeras 2 líneas, ≥5 keywords, thumbnail marcada (o WARN), idioma es, no-kids, capítulos
  presentes en la descripción. Exit ≠0 si falla algo duro.
- **`schedule`**: sugiere próximo slot según peak hours + día actual. Simple, sin ML.
- **`post`**: texto del anuncio de comunidad (REGLA DURA: solo texto al chat/publish.json,
  NUNCA insert en la BD del producto — feedback/youtube-posts.md).

## COMPONENTE 3 — Upload agéntico a YouTube Studio (navegador)

- Flujo Playwright con **perfil persistente** (dir de perfil propio del repo, p.ej.
  `~/.sfstudio/browser-profile`, NO el Chrome personal): pasos studio.youtube.com → subir archivo
  → título/descripción/tags → config repetible desde **`channel-defaults.json`** (crearlo:
  idioma es, no made-for-kids, categoría, licencia, altered-content, visibilidad default
  PRIVATE) → visibilidad → screenshots de verificación POR PASO.
- **Check de sesión primero**: abrir studio.youtube.com en el perfil. DOS ramas válidas:
  - **A (hay sesión Google)**: prueba E2E REAL con un video corto de prueba
    (`demo/out/card-916.mp4`), título `[TEST SFPublish] borrar`, como **PRIVADO** — flujo
    completo con screenshots → verificar que el draft existe → **BORRARLO** (canal limpio).
  - **B (no hay sesión)**: implementar el flujo igual (selectores robustos + pasos), correrlo
    hasta la pantalla de login (screenshot) y documentar el **ritual de conexión de 1 vez**
    (Daniel abre el perfil con un comando, loguea Google, cookies persisten).
- **PROHIBIDO**: publicar nada público; tocar/editar videos existentes del canal; programar
  nada real. Solo el draft privado de prueba, borrado al final.
- Tarjetas/pantallas finales: implementar el paso si la rama A lo permite sin riesgo (el editor
  de tarjetas de un DRAFT es seguro); si es frágil, documentar los selectores/flujo y dejarlo
  marcado `partial` en publish.json — honesto, no fingido.

## COMPONENTE 4 — Skill + docs

- Nueva `edicion-de-video/references/publicacion.md`: manual E2E del agente para la etapa 2
  (comandos, orden, gate, ramas del upload, reglas duras). Puntero MÍNIMO en SKILL.md
  (línea en el pipeline) — no inflar.
- `CLAUDE.md`/`README` del repo actualizados (sfpublish, publish.json, channel-defaults).
- `npm test` extendido: unit tests del gate del checklist + detección de menciones (fixtures
  sintéticos) + humo del panel ⌘Y en Playwright (abre, muestra etapas de un publish.json de
  prueba, 0 errores consola).

## DEFINICIÓN DE HECHO (el evaluador solo ve esta conversación — surfea TODA la evidencia)

1. **Panel**: screenshot del ⌘Y sobre el v5 real con ≥4 etapas en verde y evidencia visible +
   `publish.json` final pegado.
2. **Metadata real**: la descripción generada pegada COMPLETA (con el `/go/<slug>`) + salida del
   `curl -I` del link mostrando redirect + Set-Cookie.
3. **Menciones**: tabla de matches del transcript v5 ↔ `youtube_videos` pegada (o el resultado
   honesto "0 menciones" con la evidencia del método probado en fixture sintético).
4. **Checklist**: output del gate pegado (pasando y un caso fallando).
5. **Upload**: rama A = screenshots del flujo completo del draft privado + verificación de
   borrado; rama B = screenshots hasta login + ritual documentado. Decir CUÁL rama aplicó.
6. `npm test` verde (todo el arnés, viejo + nuevo) + 0 errores de consola + diff de la skill +
   git limpio EN MAIN.
7. Lista explícita de cómo podría estar roto/incompleto → resuelta antes de declarar terminado.

## RESTRICCIONES REALES

- Producto SFC **INTOCABLE**: cero cambios de código, cero deploys, cero inserts salvo
  `tracked_links` (idempotente). Regla de oro #1: NUNCA fabricar datos — si una métrica/tabla
  no existe, se dice.
- NUNCA publicar público en YouTube; NUNCA tocar videos existentes; draft de prueba SIEMPRE
  privado y borrado.
- Posts de comunidad: SOLO texto (sin DB inserts, sin tracked links nuevos para posts).
- Todo local. Sub-agentes SIEMPRE en Sonnet. No tocar el máster v5 ni el raw. Branch: `main`.
- SFStudio existente (sala/tests 8/8) no se rompe: el arnés viejo sigue verde.

## RED DE SEGURIDAD

80 turnos sin converger o mismo blocker x3 por la misma causa → detente y deja por escrito qué
funciona (con evidencia), qué falta y la decisión que necesitas de Daniel.
