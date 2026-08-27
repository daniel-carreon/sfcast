# Despierta — 27 ago

## ⚠️ Lo primero: te debo UN clic, y es culpa mía

Abre SFCast. Te va a pedir **«Grabación de pantalla»**: dale Permitir, cierra la app y
vuelve a abrirla. **20 segundos y ya.** Para comprobarlo sin abrir nada:

```
open -W /Applications/SFCast.app --args --permisos     # espera: pantalla=SI
```

**Qué pasó.** A las 22:51, con la Mac sola y la pantalla ya bloqueada, macOS le negó la
captura a la app —lo hace **por diseño** con la sesión bloqueada— y el "ScreenDoctor" leyó
esa negativa como un permiso podrido y corrió `tccutil reset`. Borró una aprobación que
estaba perfectamente sana. Un reparador que rompe, y de noche, que es cuando nadie mira.

Esa trampa ya estaba en el código; mis pruebas nocturnas la pisaron. **Ya está cerrada:**
con la sesión bloqueada el doctor no diagnostica ni repara nada, y el mensaje de error
ahora distingue "está bloqueada" de "falta permiso" en vez de mandarte a Ajustes por nada.

---

## Lo que estaba roto de verdad (y ya no)

**El hueco de cabeza.** Cada toma abría su archivo tantos segundos en el pasado como
durara la pausa desde la anterior — medido en tus 9 tomas de anoche: 1.07 s, 2.07 s,
6.77 s, hasta **9.47 s**. Por eso la primera toma siempre salía bien y de la segunda en
adelante "se lageaba". Y las alarmas que te gritaban `PEOR TRAMO 0.0 fps` y `EL MATERIAL SE
MUEVE A 57%` **decían la verdad**: medían ese hueco. Se leyeron como ruido.

**Tu pantalla se dormía a los 5 minutos.** Hablar a cámara sin tocar el teclado es
exactamente eso. Al apagarse el monitor, ScreenCaptureKit se queda sin pantalla y el stream
muere. OBS se protege de esto desde siempre; SFCast no. Ahora sí, mientras grabas.

**El micrófono se moría y no volvía.** En la prueba larga el Shure entregó 39,363 muestras
en la toma 1, 8,050 en la 2 y **cero** desde ahí; el guard de voz auto-detenía cada toma
siguiente a los 20 s, para siempre, porque nadie volvía a pegar el micro. Ya tiene watchdog,
como la cámara desde el 9 ago.

## Cómo quedó, medido

| | antes | ahora |
|---|---|---|
| 6 tomas encadenadas (7 min c/u) | 30.6 → 13.6 fps (**−55.6%**) | 30.01 → 30.01 fps (**−0.0%**) |
| hueco al arrancar la toma | 1 a 9.5 s | **0.000 s** en las 6 |
| movimiento real (`qa-unique-fps`) | 48.6% · QA_FAIL | **89.2% y 90.0%** · QA_OK |
| 42 min de grabación | — | 0 drops · 0 sin-buffer · 0 reenganches |
| 10 min de preview sin grabar | se congeló | 40/40 latidos a 30 fps |

## Si algo sale mal

```
osascript -e 'tell application "SFCast" to quit'
cp -R ~/Applications/SFCast-ROLLBACK-2026-08-26.app /Applications/SFCast.app
```
**Cierra la app antes de copiar.** Eso sí rompe el permiso de pantalla — no el rebuild, que
era el mito que este repo creyó durante un mes.

## Tres cosas que quiero que sepas, ninguna urgente

**Grabas la pantalla `#5`, que no es tu principal (`#2`).** La elegiste el 25 ago; verifica
que sea la que miras mientras das la clase.

**Tu ZV-E10 emite 25p.** Con lienzo a 30, uno de cada seis frames de tu cara repite. El
código ya pide la mejor cadencia disponible, pero los frames no se inventan: ponle
**NTSC / 30p** a la cámara y ganas ~20% de movimiento. Dos minutos de menú.

**El cuelgue del preview no tiene causa raíz confirmada.** Maté al sospechoso número uno (el
ScreenDoctor abría un diálogo modal 2.5 s después de cada apertura del Estudio, y un modal
congela todos los sensores). Si vuelve: la app **sigue grabando por dentro** aunque la
ventana parezca muerta — **no la fuerces a cerrar**. Te avisa por notificación y deja la
pila en `~/Library/Logs/sfcast-cuelgue-*.txt`, que dirá qué línea fue.

_Detalle completo: `DECISIONS.md` §v3.7._
