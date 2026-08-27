# Despierta — 27 ago

# ⚠️ UN SOLO GESTO: abre SFCast y pulsa **«Permitir»**

Eso es todo. Al abrirla te saldrá el diálogo de macOS pidiendo **«Grabación de pantalla»**:
le das Permitir y **la app se reabre sola** para aplicarlo. Un clic, unos segundos, y a
grabar. No tienes que cerrar nada ni entrar a Ajustes.

Comprobarlo, si quieres: `open -W /Applications/SFCast.app --args --permisos` → `pantalla=SI`.

**Por qué te debo ese clic.** A las 22:51, con la Mac sola y la pantalla ya bloqueada, macOS
le negó la captura a la app —lo hace **por diseño** con la sesión bloqueada— y el
"ScreenDoctor" leyó esa negativa como un permiso podrido y corrió `tccutil reset`. Borró una
aprobación perfectamente sana. Intenté devolvértela sin molestarte y no se puede: TCC.db está
protegido por SIP, y lanzar el diálogo con la pantalla bloqueada lo dejaría huérfano — y un
diálogo huérfano se resuelve como **DENEGADO**, que sería peor. La trampa ya estaba en el
código; mis pruebas nocturnas la pisaron. **Ya está cerrada** y verificada en la misma
condición que la causó.

---

## Lo que estaba roto de verdad (y ya no)

**El hueco de cabeza.** Cada toma abría su archivo tantos segundos en el pasado como durara
la pausa desde la anterior — en tus 9 tomas de anoche: 1.07 s, 2.07 s, 6.77 s, hasta
**9.47 s**. Por eso la primera toma siempre salía bien y de la segunda en adelante "se
lageaba". Las alarmas que te gritaban `PEOR TRAMO 0.0 fps` y `EL MATERIAL SE MUEVE A 57%`
**decían la verdad**: medían ese hueco. Se leyeron como ruido.

**Tu pantalla se dormía a los 5 minutos** y hablar a cámara es exactamente eso. Al apagarse
el monitor, ScreenCaptureKit se queda sin pantalla y el stream muere. OBS se protege desde
siempre; SFCast no. Ahora sí, mientras grabas.

**El micrófono se moría y no volvía.** En la prueba larga: 39,363 muestras en la toma 1,
8,050 en la 2, cero desde ahí. El guard de voz auto-detenía cada toma siguiente a los 20 s,
para siempre. Ya tiene watchdog, como la cámara desde el 9 ago.

## Cómo quedó, medido

| | antes | ahora |
|---|---|---|
| 6 tomas encadenadas (7 min c/u) | 30.6 → 13.6 fps (**−55.6%**) | 30.01 → 30.01 (**−0.0%**) |
| hueco al arrancar la toma | 1.0 a 9.5 s | **0.000 s** en las 6 |
| movimiento real (`qa-unique-fps`) | 48.6% · QA_FAIL | **89.2%** y **90.0%** · QA_OK |
| 42 min grabando | — | 0 drops · 0 sin-buffer · 0 reenganches |
| 10 min de preview sin grabar | se congeló | 40/40 latidos a 30 fps |

## Tres cosas que quiero que sepas, ninguna urgente

**Grabas la pantalla `#5`, que no es tu principal (`#2`).** La elegiste el 25 ago; verifica
que sea la que miras mientras das la clase.

**Tu ZV-E10 emite 25p.** Con lienzo a 30, uno de cada seis frames de tu cara repite. Ponle
**NTSC / 30p** y ganas ~20% de movimiento. Dos minutos de menú.

**El cuelgue del preview no tiene causa raíz confirmada.** Maté al sospechoso número uno.
Si vuelve: la app **sigue grabando por dentro** aunque la ventana parezca muerta — **no la
fuerces a cerrar**. Te avisa y deja la pila en `~/Library/Logs/sfcast-cuelgue-*.txt`.

---

_Botón de pánico, por si acaso — no hace falta si todo va bien:_
```
osascript -e 'tell application "SFCast" to quit'
cp -R ~/Applications/SFCast-ROLLBACK-2026-08-26.app /Applications/SFCast.app
```
_Vuelve al build de anoche. Cierra la app antes de copiar._

_Detalle completo: `DECISIONS.md` §v3.7 y §v3.7b._
