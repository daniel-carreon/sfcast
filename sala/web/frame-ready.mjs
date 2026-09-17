// A currentTime assignment is not proof that the decoder has presented that frame.
export function frameReady(el, target, tolerance) {
  if (el.tagName !== 'VIDEO') return Boolean(el.complete && el.naturalWidth);
  return el.readyState >= 2 && !el.seeking && Math.abs(el.currentTime-target)<=tolerance &&
    (!el._presented || Math.abs(el._presented.mediaTime-target)<=tolerance);
}
