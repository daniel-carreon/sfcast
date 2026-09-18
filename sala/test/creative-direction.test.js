import {test} from 'node:test';
import assert from 'node:assert/strict';
import {projectDirection,creativeDirection} from '../lib/creative-direction.js';
import {promises as fs} from 'node:fs';
import os from 'node:os';
import path from 'node:path';
test('decisions distinguish excluded, planned, missing and declared review',()=>{
 const r=projectDirection({intro:{logos:{use:true,reason:'brand'},depth_3d:{use:false,reason:'rejected'},sound:{use:true}},review:{audio_sync:{checked:true},face_clear:{checked:true,evidence:'sample only'}},artistic_approval:false});
 assert.equal(r.decisions.find(x=>x.id==='logos').status,'planned');
 assert.equal(r.decisions.find(x=>x.id==='depth_3d').status,'excluded');
 assert.equal(r.decisions.find(x=>x.id==='sound').status,'pending');
 assert.equal(r.checks.find(x=>x.id==='audio_sync').status,'pending');
 assert.equal(r.checks.find(x=>x.id==='face_clear').status,'reported');
 assert.equal(r.artistic_approval,false);
});
test('missing and broken direction remain pending without inventing approval',async()=>{
 const d=await fs.mkdtemp(path.join(os.tmpdir(),'sf-direction-'));
 try{
  assert.equal((await creativeDirection(d)).state,'missing');
  await fs.mkdir(path.join(d,'design'));await fs.writeFile(path.join(d,'design/direccion.json'),'{bad');
  const r=await creativeDirection(d);assert.equal(r.state,'invalid');assert.equal(r.artistic_approval,false);
  assert.ok(r.decisions.every(x=>x.status==='pending'));
 }finally{await fs.rm(d,{recursive:true,force:true});}
});
