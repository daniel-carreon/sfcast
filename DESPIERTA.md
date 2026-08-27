# Despierta — 27 ago, 05:30

**No tienes que hacer nada. Abre SFCast y graba.** El permiso de pantalla sigue vivo
(lo verifiqué en 7 reinstalaciones seguidas: el mito de "un clic por rebuild" era falso).

**Lo que estaba roto:** cada toma abría su archivo tantos segundos en el pasado como
hubiera durado la pausa desde la anterior (medido: hasta 9.5 s). Por eso la 1ª toma
siempre salía bien y de la 2ª en adelante "se lageaba". Arreglado y probado: 6 tomas
encadenadas, 30.5 fps parejos, cero hueco. **Y tu pantalla se dormía a los 5 minutos**
— si hablabas a cámara sin tocar el teclado, el monitor se apagaba a media toma. Ahora
la app lo impide mientras grabas.

**Si algo sale mal:** `cp -R ~/Applications/SFCast-ROLLBACK-2026-08-26.app /Applications/SFCast.app`
(cierra SFCast antes de copiar). Vuelves al build de anoche sin perder el permiso.

**Tres cosas que quiero que sepas, ninguna urgente:** grabas la pantalla `#5`, que no es
tu principal (`#2`) — lo elegiste el 25 ago, revisa que sea la que miras. Tu cámara
entrega **25 fps** contra un lienzo de 30; si pones la ZV-E10 en 30p, la burbuja va más
suave. Y el cuelgue del preview que te tiró anoche **no tiene causa raíz confirmada**:
dejé un vigía que lo detecta en 3 s, te notifica y vuelca la pila en
`~/Library/Logs/sfcast-cuelgue-*.txt` — si vuelve a pasar, ese archivo dice qué fue.

_Detalle completo: `DECISIONS.md` §v3.7. Reporte de la noche: al final de este archivo._
