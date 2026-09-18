import {test} from 'node:test';
import assert from 'node:assert/strict';
import {promises as fs} from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {loadPublish,savePublish,newPublish} from '../lib/publish.js';
import {applyGalleryPatch} from '../lib/gallery.js';

test('CLI cannot overwrite a newer gallery edit, then can reload and save',async()=>{
 const dir=await fs.mkdtemp(path.join(os.tmpdir(),'sf-pub-'));
 try {
  await savePublish(dir,newPublish('fixture'));
  const stale=await loadPublish(dir);
  await applyGalleryPatch(dir,{description:'Human correction'});
  stale.data.youtube={video_id:'abcdefghijk'};
  await assert.rejects(savePublish(dir,stale),/cambió/);
  const fresh=await loadPublish(dir);
  assert.equal(fresh.data.metadata.description,'Human correction');
  fresh.data.youtube={video_id:'abcdefghijk'};
  await savePublish(dir,fresh);
  assert.equal((await loadPublish(dir)).data.youtube.video_id,'abcdefghijk');
  await fs.writeFile(path.join(dir,'.gallery-write.lock'),'');
  await assert.rejects(savePublish(dir,fresh),/Otra escritura/);
  assert.equal((await loadPublish(dir)).data.metadata.description,'Human correction');
 }finally{await fs.rm(dir,{recursive:true,force:true});}
});
test('invalid publication is not silently treated as a new project',async()=>{
 const dir=await fs.mkdtemp(path.join(os.tmpdir(),'sf-pub-'));
 try {
  await fs.writeFile(path.join(dir,'publish.json'),'{broken');
  await assert.rejects(loadPublish(dir),SyntaxError);
  await assert.rejects(savePublish(dir,newPublish('fixture')),SyntaxError);
  assert.equal(await fs.readFile(path.join(dir,'publish.json'),'utf8'),'{broken');
 }finally{await fs.rm(dir,{recursive:true,force:true});}
});
