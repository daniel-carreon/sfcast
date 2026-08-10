#!/usr/bin/env python3
"""Genera `play-titanium.png`: el boton de play de SFCast como PNG transparente.

Por que un PNG y no CSS: este boton es para el CORREO. Ningun cliente de email
ejecuta iframes ni JS, y los que sobreviven (Outlook con Word como motor) tampoco
respetan gradientes ni box-shadow. La unica forma de que el miembro vea el mismo
boton negro con el triangulo dorado es que venga HORNEADO en la imagen.

Se corre UNA vez y el PNG se versiona junto al script. Luego `publish_cast_r2.py`
lo compone con ffmpeg sobre la portada de cada cast, sin dependencias nuevas en
el VPS (PIL vive aqui, ffmpeg alla).

Uso:  python3 make_play_button.py [salida.png]
"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

# Paleta Titaniumorphism (identica a --titanium-* / --gold del producto)
TOP, MID, BOT = (0x24, 0x24, 0x2B), (0x16, 0x16, 0x1C), (0x0D, 0x0D, 0x12)
BORDE, BORDE_TOP = (0x2C, 0x2C, 0x34), (0x42, 0x42, 0x4C)
GOLD = (0xFF, 0x91, 0x01)

LIENZO = 320          # con aire para el halo
BOTON = 168           # diametro del disco de metal
SS = 4                # supersampling: se dibuja 4x y se baja → bordes limpios


def _disco_metal(d: int) -> Image.Image:
    """Disco con degradado vertical top→mid→bot (la luz cae desde arriba)."""
    grad = Image.new("RGB", (1, d))
    px = grad.load()
    for y in range(d):
        t = y / max(1, d - 1)
        if t < 0.52:
            k = t / 0.52
            c = tuple(round(TOP[i] + (MID[i] - TOP[i]) * k) for i in range(3))
        else:
            k = (t - 0.52) / 0.48
            c = tuple(round(MID[i] + (BOT[i] - MID[i]) * k) for i in range(3))
        px[0, y] = c
    return grad.resize((d, d))


def construir() -> Image.Image:
    L, B = LIENZO * SS, BOTON * SS
    img = Image.new("RGBA", (L, L), (0, 0, 0, 0))
    cx = L // 2

    # 1) halo mostaza por detras (glow del sistema)
    halo = Image.new("RGBA", (L, L), (0, 0, 0, 0))
    hd = ImageDraw.Draw(halo)
    r = int(B * 0.78)
    hd.ellipse([cx - r, cx - r, cx + r, cx + r], fill=GOLD + (150,))
    halo = halo.filter(ImageFilter.GaussianBlur(B * 0.20))
    img = Image.alpha_composite(img, halo)

    # 2) sombra de contacto: despega el boton de cualquier miniatura
    sombra = Image.new("RGBA", (L, L), (0, 0, 0, 0))
    sd = ImageDraw.Draw(sombra)
    r = B // 2
    sd.ellipse([cx - r, cx - r + int(B * 0.10), cx + r, cx + r + int(B * 0.10)],
               fill=(0, 0, 0, 190))
    sombra = sombra.filter(ImageFilter.GaussianBlur(B * 0.12))
    img = Image.alpha_composite(img, sombra)

    # 3) el disco de metal, recortado en circulo
    metal = _disco_metal(B).convert("RGBA")
    mask = Image.new("L", (B, B), 0)
    ImageDraw.Draw(mask).ellipse([0, 0, B - 1, B - 1], fill=255)
    metal.putalpha(mask)
    img.alpha_composite(metal, (cx - B // 2, cx - B // 2))

    d = ImageDraw.Draw(img)
    r = B // 2
    caja = [cx - r, cx - r, cx + r, cx + r]
    # 4) filo: mitad superior iluminada, inferior hundida (volumen)
    d.arc(caja, start=180, end=360, fill=BORDE_TOP + (255,), width=max(2, int(B * 0.011)))
    d.arc(caja, start=0, end=180, fill=BORDE + (255,), width=max(2, int(B * 0.011)))
    ib = int(B * 0.030)
    d.arc([caja[0] + ib, caja[1] + ib, caja[2] - ib, caja[3] - ib],
          start=185, end=355, fill=(255, 255, 255, 46), width=max(2, int(B * 0.010)))

    # 5) triangulo como TIRA LED: solo perimetro encendido, centro de metal.
    #    Centroide en 12,12 del viewBox 24 → centra optico sin correrlo a mano.
    esc = B / 24 * 0.55
    o = cx - 12 * esc
    pts = [(o + 6 * esc, o + 3.7 * esc), (o + 20.1 * esc, o + 12 * esc),
           (o + 6 * esc, o + 20.3 * esc)]
    brillo = Image.new("RGBA", (L, L), (0, 0, 0, 0))
    ImageDraw.Draw(brillo).line(pts + [pts[0]], fill=GOLD + (255,),
                                width=int(B * 0.030), joint="curve")
    img = Image.alpha_composite(img, brillo.filter(ImageFilter.GaussianBlur(B * 0.035)))
    ImageDraw.Draw(img).line(pts + [pts[0]], fill=GOLD + (255,),
                             width=int(B * 0.026), joint="curve")

    return img.resize((LIENZO, LIENZO), Image.LANCZOS)


if __name__ == "__main__":
    salida = Path(sys.argv[1] if len(sys.argv) > 1
                  else Path(__file__).parent / "play-titanium.png")
    img = construir()
    img.save(salida)
    print(f"{salida} · {salida.stat().st_size/1024:.0f} KB · {img.size[0]}x{img.size[1]}")
