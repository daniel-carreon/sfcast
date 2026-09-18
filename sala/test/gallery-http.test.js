import {test} from 'node:test';
import assert from 'node:assert/strict';
import {promises as fs} from 'node:fs';
import {spawn,execFileSync} from 'node:child_process';
import {setTimeout as delay} from 'node:timers/promises';
import path from 'node:path';
import os from 'node:os';
import {fileURLToPath} from 'node:url';
const cli=fileURLToPath(new URL('../bin/sfreview.js',import.meta.url));
async function launch(dir,root){
 await fs.rm(path.join(dir,'sala-handle.json'),{force:true});
 const child=spawn(process.execPath,[cli,dir,'--port','0','--roots',root],{stdio:['ignore','pipe','pipe']});
 let log='';child.stdout.on('data',x=>log+=x);child.stderr.on('data',x=>log+=x);
 const stop=async()=>{if(child.exitCode!==null)return;child.kill('SIGTERM');await Promise.race([new Promise(r=>child.once('exit',r)),delay(5000)]);};
 try {
  for(let i=0;i<100;i++){
   if(child.exitCode!==null)throw new Error(log);
   try{const h=JSON.parse(await fs.readFile(path.join(dir,'sala-handle.json')));if(h.port)return {url:`http://127.0.0.1:${h.port}`,stop};}catch{}
   await delay(100);
  }
  throw new Error(`Server failed: ${log}`);
 }catch(e){await stop();throw e;}
}
for(const format of ['modern','legacy'])test(`${format} launcher preserves roots; gallery edit persists after process restart and rejects stale saves`,async()=>{
 const root=await fs.mkdtemp(path.join(os.tmpdir(),'sf-gallery-http-'));const dir=path.join(root,'example');await fs.mkdir(dir);
 let room;
 try{
  execFileSync('ffmpeg',['-v','error','-f','lavfi','-i','color=black:s=64x64:r=25','-t','1','-c:v','libx264',path.join(dir,'source.mp4')]);
  const doc=format==='modern'?{fps:25,width:64,height:64,sources:{c:{path:'source.mp4'}},cuts:[{id:'one',source:'c',source_start:0,source_end:1}],events:[],score:{cues:[]}}:{name:'Legacy',fps:25,width:64,height:64,duration:1,base:{src:'source.mp4'},items:[]};
  const projectName=format==='modern'?'project.json':'timeline.json';const raw=JSON.stringify(doc);await fs.writeFile(path.join(dir,projectName),raw);
  await fs.writeFile(path.join(dir,'publish.json'),JSON.stringify({video:{titulo:'Fixture'},data:{post_draft:{body:'Draft',approved_at:null}}}));
  room=await launch(dir,root);
  const health=await (await fetch(room.url+'/api/health')).json();assert.equal(await fs.realpath(health.project),await fs.realpath(dir));
  const catalog=await (await fetch(room.url+'/api/gallery')).json();assert.equal(catalog.items.length,1);assert.equal(catalog.items[0].id,'r0/example');
  const item=await (await fetch(room.url+'/api/gallery/item?id=r0/example')).json();
  const patch={publication_revision:item.publication_revision,description:'Saved through actual HTTP'};
  const response=await fetch(room.url+'/api/gallery/item?id=r0/example',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(patch)});
  assert.equal(response.status,200,await response.clone().text());
  const stale=await fetch(room.url+'/api/gallery/item?id=r0/example',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({...patch,description:'Stale overwrite'})});
  assert.ok([400,409].includes(stale.status));
  await room.stop();room=await launch(dir,root);
  const reread=await (await fetch(room.url+'/api/gallery/item?id=r0/example')).json();assert.equal(reread.description,patch.description);assert.equal(reread.post.approved_at,null);
  assert.equal(await fs.readFile(path.join(dir,projectName),'utf8'),raw);
 }finally{if(room)await room.stop();await fs.rm(root,{recursive:true,force:true});}
});
