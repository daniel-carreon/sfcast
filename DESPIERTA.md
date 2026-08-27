# Despierta — 27 ago, 05:30

**No tienes que hacer nada. Abre SFCast y graba.** El permiso de pantalla sigue vivo:
el invariante que decía "un clic por cada rebuild" era falso, y lo verifiqué en más de
10 reinstalaciones seguidas.

## Lo que estaba roto (y ya no)

**El hueco de cabeza.** Cada toma abría su archivo tantos segundos en el pasado como
durara la pausa desde la anterior — medido en tus 9 tomas de anoche: 1.07 s, 2.07 s,
6.77 s, hasta **9.47 s**. Por eso la primera toma siempre salía bien y de la segunda en
adelante "se lageaba". Y las alarmas que te gritaban `PEOR TRAMO 0.0 fps` y `EL MATERIAL
SE MUEVE A 57%` **decían la verdad**: medían ese hueco. A/B: **13.56 → 30.57 fps**.

**Tu pantalla se dormía a los 5 minutos.** Hablar a cámara sin tocar el teclado es
exactamente eso. Cuando el monitor se apaga, ScreenCaptureKit se queda sin pantalla y el
stream se cae — está dos veces en tu log de ayer. OBS se protege de esto desde siempre;
SFCast no. Ahora sí, mientras grabas.

**El micrófono se moría y no volvía.** Lo cacé en la prueba larga: el Shure entregó
39,363 muestras en la toma 1, 8,050 en la 2, y **cero** desde ahí. El guard de voz
auto-detenía cada toma siguiente a los 20 s, correctamente y para siempre, porque nadie
volvía a pegar el micro. La cámara tenía ese remedio desde el 9 ago; el micro no. Ya lo
tiene.

## Si algo sale mal

```
osascript -e 'tell application "SFCast" to quit'
cp -R ~/Applications/SFCast-ROLLBACK-2026-08-26.app /Applications/SFCast.app
```
Vuelves al build de anoche sin perder el permiso. **Cierra la app antes de copiar** — eso
sí rompe el permiso de pantalla (no el rebuild, como se creía).

## Tres cosas que quiero que sepas, ninguna urgente

**Grabas la pantalla `#5`, que no es tu principal (`#2`).** La elegiste el 25 ago;
verifica que sea la que miras mientras das la clase.

**Tu ZV-E10 está emitiendo 25p.** Con un lienzo a 30, uno de cada seis frames de tu cara
repite. El código ya pide automáticamente la mejor cadencia disponible, pero los frames
no se inventan: si le pones **NTSC / 30p** a la cámara, la burbuja se mueve un 20% más.
Son dos minutos de menú.

**El cuelgue del preview no tiene causa raíz confirmada.** Desactivé el sospechoso número
uno (el ScreenDoctor abría un diálogo modal 2.5 s después de cada apertura del Estudio, y
un modal congela todos los sensores). Si vuelve a pasar: la app **sigue grabando por
dentro** aunque la ventana parezca muerta, así que **no la fuerces a cerrar** — te avisará
por notificación y dejará la pila del cuelgue en `~/Library/Logs/sfcast-cuelgue-*.txt`,
que dirá exactamente qué línea fue.

_Detalle completo: `DECISIONS.md` §v3.7._
