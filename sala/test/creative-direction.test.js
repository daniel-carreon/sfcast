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

test('review report is bound to direction and montage; changed direction invalidates it',async()=>{
 const {recordRun,readRuns}=await import('../lib/project-history.js');
 const dir=await fs.mkdtemp(path.join(os.tmpdir(),'sf-review-proof-'));
 try {
  await fs.mkdir(path.join(dir,'design'));
  await fs.writeFile(path.join(dir,'project.json'),JSON.stringify({sources:{}}));
  await fs.writeFile(path.join(dir,'design/direccion.json'),JSON.stringify({intro:{intent:'Original'}}));
  await fs.writeFile(path.join(dir,'report.json'),'{}');
  const input={summary:'Coverage only',standard_revision:'fixture',result:'passed',evidence:['report.json'],standard_files:[],motor_files:[],creative_checks:[{id:'preview_cta',method:'structural',scope:'Layout coverage, not face detection'}]};
  await recordRun(dir,input);
  let projected=await creativeDirection(dir,await readRuns(dir));
  let check=projected.checks.find(c=>c.id==='preview_cta');
  assert.equal(check.status,'pending'); // A structural test is not visual review.
  assert.equal(check.verification[0].freshness,'matching');
  assert.equal(projected.artistic_approval,false);
  await fs.writeFile(path.join(dir,'design/direccion.json'),JSON.stringify({intro:{intent:'Changed'}}));
  projected=await creativeDirection(dir,await readRuns(dir));
  check=projected.checks.find(c=>c.id==='preview_cta');
  assert.equal(check.verification[0].freshness,'invalidated');
  assert.ok(check.verification[0].reasons.includes('cambió la dirección creativa'));
  await assert.rejects(recordRun(dir,{...input,creative_checks:[{id:'preview_cta',method:'structural'}]}),/alcance/);
  await assert.rejects(recordRun(dir,{...input,evidence:[]}),/reporte/);
 }finally{await fs.rm(dir,{recursive:true,force:true});}
});
