// One decoder owns picture + sound; editing coordinates remain source-time.
export function sourceAtOutput(p,t){
 const cs=p?.cuts||[];const f=t*p.fps;
 const c=cs.find(c=>f>=c.start_frame&&f<c.start_frame+c.duration_frames)||cs.at(-1);
 return c?Math.min(c.source_end,c.source_start+Math.max(0,f-c.start_frame)/p.fps):0;
}
export function outputAtSource(p,t){
 const cs=p?.cuts||[];let c=cs.find(c=>t>=c.source_start&&t<=c.source_end);
 if(!c){let best=0,dist=Infinity;for(const x of cs){for(const [raw,out] of [[x.source_start,x.start_frame],[x.source_end,x.start_frame+x.duration_frames]]){if(Math.abs(raw-t)<dist){dist=Math.abs(raw-t);best=out/p.fps;}}}return best;}
 return (c.start_frame+Math.min(c.duration_frames,(t-c.source_start)*p.fps))/p.fps;
}
export function composedTransport(raw,movie,getProject){
 let enabled=false;const active=()=>enabled?movie:raw;
 const proxy=new Proxy(raw,{
  get(target,key){
   if(key==='currentTime')return enabled?sourceAtOutput(getProject(),movie.currentTime):raw.currentTime;
   if(key==='duration')return enabled?getProject().duration:raw.duration;
   if(key==='addEventListener')return (name,fn,opts)=>{raw.addEventListener(name,fn,opts);movie.addEventListener(name,fn,opts);};
   if(key==='requestVideoFrameCallback')return fn=>active().requestVideoFrameCallback((now,meta)=>fn(now,enabled?{...meta,mediaTime:sourceAtOutput(getProject(),meta.mediaTime)}:meta));
   const value=active()[key];return typeof value==='function'?value.bind(active()):value;
  },
  set(target,key,value){if(key==='currentTime'){active().currentTime=enabled?outputAtSource(getProject(),value):value;return true;}active()[key]=value;return true;}
 });
 return {proxy,active:()=>enabled,setEnabled(value){raw.pause();movie.pause();enabled=value;},movie};
}
