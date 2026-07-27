// web/icons.js — iconos Lucide (lucide.dev, ISC) como SVG inline. Cero dependencias, cero build.
// Un solo lugar: la Sala y la Galería usan LOS MISMOS iconos (si divergen, driftean).

const svg = (paths, w = 2) => `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="${w}" stroke-linecap="round" stroke-linejoin="round">${paths}</svg>`;

export const ICON_COPY = svg('<rect width="14" height="14" x="8" y="8" rx="2" ry="2"/><path d="M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2"/>');
export const ICON_CHECK = svg('<path d="M20 6 9 17l-5-5"/>', 2.5);
export const ICON_EXPAND = svg('<path d="M15 3h6v6"/><path d="M9 21H3v-6"/><path d="M21 3l-7 7"/><path d="M3 21l7-7"/>');

/** Cablea un botón icon-only de copiar: pinta el icono y da el feedback de ✓ al usarlo. */
export function paintCopy(btn) { btn.innerHTML = ICON_COPY; }
export function flashCopied(btn) {
  btn.innerHTML = ICON_CHECK;
  btn.classList.add('ok');
  setTimeout(() => { btn.innerHTML = ICON_COPY; btn.classList.remove('ok'); }, 1400);
}
