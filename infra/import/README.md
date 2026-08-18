# Importador de video externo → SFCast

El worker de SFCast publica **grabaciones nuevas** (incoming → transcribe → LLM → viewer).
Estos scripts hacen lo mismo para **video que ya existe en otra plataforma**, y fueron
escritos para migrar el classroom de SaaS Factory desde Loom (51 videos, 6.95 GB).

> ⚠️ **Los casts NATIVOS ya no se quedan fuera de R2** (10 ago 2026).
> Esta migración fue de una sola vez y `publish_r2.py` decía explícito que *"los casts
> nativos que ya vivían en el VPS NO se tocan"*. Pero el frontend de la comunidad arma el
> embed contra R2 para **cualquier** id, así que un cast recién grabado se veía como la
> página *"Is this your bucket?"* de Cloudflare dentro del post — le pasó a un anuncio de
> ~570 miembros. Desde entonces existe [`../publish_cast_r2.py`](../publish_cast_r2.py),
> que hace lo mismo para casts nativos y **lo llama el worker solo** al terminar de
> publicar. Reutiliza el `embed_html()` de `publish_preview_embeds.py`: ese archivo sigue
> siendo la fuente única del embed, y tocarlo cambia los dos caminos.
>
> Dos cosas medidas ese día, para que nadie las repita:
> - **El sensor no puede preguntarle a `r2.dev`.** Cloudflare lo limita por tasa y devuelve
>   rojo sobre objetos que sí existen (dio "61 faltantes" con 52 publicados, y "0/9" con los
>   9 puestos). El censo se hace con `rclone lsf`, que es el autoritativo.
> - **`card.gif` / `card.jpg`** son el video para el CORREO: ningún cliente de email ejecuta
>   iframes, así que viaja como imagen con el botón de play horneado
>   (`../assets/play-titanium.png`).

## El pipeline

```
Loom ──► download.py ──► ingest_vps.py ──► make_previews.py ──► publish_preview_embeds.py ──► R2
         (yt-dlp 1080p)   (formato SFCast)   (portada animada)    (embed + subida)
```

| Script | Qué hace | Dónde corre |
|---|---|---|
| `download.py` | Baja los videos a máxima calidad. Idempotente (salta lo hecho), reanudable vía `state.json` | VPS (o Mac con `OUT_DIR`) |
| `ingest_vps.py` | Convierte cada mp4 al formato SFCast: `media/<id>/{video.mp4,thumb.jpg,data.json}` + `/v/` + `/embed/`. ID determinista por hash → re-correr no duplica | VPS |
| `make_previews.py` | Portada animada estilo Loom: 5s mudos en loop, ~30 KB | VPS |
| `publish_preview_embeds.py` | Escribe el embed (Titaniumorphism) y sube todo a R2 | VPS |

## Decisiones que costaron caro

**Bajar en el VPS, no en el Mac.** Subir 7 GB desde una conexión doméstica iba a tomar
~20 horas a ~7 MB/min. Corriendo `download.py` en el VPS: 17-33s por video y cero subida.

**R2 en vez del VPS como origen.** Sirviendo desde el VPS, el throughput agregado se
saturaba en ~1.3 MB/s: con 6 espectadores simultáneos ninguno alcanzaba los 400 KB/s que
necesita un 1080p. Desde R2, 50 concurrentes dan 92.8 MB/s agregado (mediana 1,845 KB/s
cada uno) y el egress no se cobra.

**Preview en mp4, no en GIF.** Un GIF de 5s pesa megas; estos pesan 24-39 KB. El frontend
de la comunidad ya arrastraba un bug conocido por un GIF de 1 MB de Loom.

**El preview arranca al 10% del video**, no en el segundo 0: el arranque suele ser pantalla
negra o el presentador acomodándose.

**`index.html` explícito en la URL del embed.** R2 es object storage: no resuelve el
documento índice de un directorio como sí hacía Caddy con `try_files`. Pedir `/embed/<id>/`
devuelve 404; hay que pedir `/embed/<id>/index.html`.

**Excluir los temporales al subir.** yt-dlp deja `.part` y fragmentos `fhls-raw` mientras
baja; si corren descarga y subida a la vez, rclone los sube a medio escribir y falla el
checksum. Los scripts filtran solo `.mp4` finales.

## Uso

```bash
# en el VPS, con rclone configurado con el remote r2:
cd /opt/sfcast/import
OUT_DIR=/opt/sfcast/import/videos python3 download.py     # 1) bajar
python3 ingest_vps.py inventory.json                      # 2) formato SFCast
python3 make_previews.py                                  # 3) portadas animadas
python3 publish_preview_embeds.py                         # 4) embeds + subir a R2
```

`inventory.json` es la lista a migrar: `[{loom_id, title, curso, lesson_id}, ...]`.

## Pendiente

El origen público actual es el subdominio `r2.dev`, que Cloudflare limita por tasa y
declara no apto para producción. Para producción: un Worker delante de R2 (dominio
`workers.dev` gratis, sin ese límite, y permite firmar/proteger las URLs del mp4).
