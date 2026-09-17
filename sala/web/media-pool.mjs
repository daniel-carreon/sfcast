// Share a decoder only when file, track and media-to-output clock are identical.
export function mediaKey(it,fps) {
 return `${it.src}|${it.track||1}|${Math.round(((it.offset||0)-(it.start_frame||0)/fps)*fps)}`;
}
export function poolItems(items,t,out,fps,adapter,window=3){
 const groups=new Map();
 for(const it of items){
  if(it.type==='audio')continue;
  const a=adapter?it.start_frame/fps:it.start;
  const b=a+(adapter?it.duration_frames/fps:it.dur);
  if(out<a-window||out>=b+window)continue;
  const key=adapter?mediaKey(it,fps):it._key;
  const active=t>=it.start&&t<it.start+it.dur;
  const previous=groups.get(key);
  if(!previous||active)groups.set(key,{...it,_key:key,poolActive:active});
 }
 return [...groups.values()];
}
