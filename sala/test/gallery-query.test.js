import { test } from 'node:test';
import assert from 'node:assert/strict';
import { promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { query } from '../bin/gallery-query.js';
import { projectResources, resolveResource } from '../lib/project-resources.js';
import { initIdentity, recordRun, readRuns } from '../lib/project-history.js';

test('identity survives root reorder and folder move; initialization is concurrent and idempotent', async () => {
  const root=await fs.mkdtemp(path.join(os.tmpdir(),'sf-identity-'));
  try {
    const a=path.join(root,'a'), b=path.join(root,'b');
    const project=path.join(a,'original');
    await fs.mkdir(project,{recursive:true}); await fs.mkdir(b);
    await fs.writeFile(path.join(project,'project.json'),'{"name":"Original"}');
    const results=await Promise.all([initIdentity(project),initIdentity(project)]);
    assert.equal(results[0].id,results[1].id);
    const id=`p/${results[0].id}`;
    assert.equal((await query({project,roots:[a,b],action:'list'})).items[0].id,id);
    const moved=path.join(b,'renamed');await fs.rename(project,moved);
    const dossier=await query({project:moved,roots:[b,a],action:'item',id});
    assert.equal(dossier.titulo,'Original');
    assert.equal(dossier.production.identity.id,results[0].id);
    assert.equal(await fs.readFile(path.join(moved,'project.json'),'utf8'),'{"name":"Original"}');
    await fs.cp(moved,path.join(a,'duplicate'),{recursive:true});
    await assert.rejects(query({project:moved,roots:[a,b],action:'list'}),/duplicada/);
  }finally{await fs.rm(root,{recursive:true,force:true});}
});

test('history requires evidence and invalidates changed revision or missing evidence', async () => {
  const dir=await fs.mkdtemp(path.join(os.tmpdir(),'sf-history-'));
  try {
    await fs.writeFile(path.join(dir,'project.json'),'{}');
    const input={summary:'Prueba de contrato',standard_revision:'sha256:test-only',result:'passed'};
    await assert.rejects(recordRun(dir,input),/evidencia/);
    await fs.writeFile(path.join(dir,'proof.txt'),'checked');
    const run=await recordRun(dir,{...input,evidence:['proof.txt']});
    assert.equal((await readRuns(dir))[0].freshness,'matching');
    await fs.writeFile(path.join(dir,'project.json'),'{"changed":true}');
    assert.deepEqual((await readRuns(dir))[0].invalidation_reasons,['cambió el proyecto']);
    await fs.unlink(path.join(dir,'proof.txt'));
    const after=(await readRuns(dir))[0];
    assert.equal(after.id,run.id);
    assert.ok(after.invalidation_reasons.includes('falta evidencia'));
    const stored=JSON.parse(await fs.readFile(path.join(dir,'.sfstudio/runs',run.id+'.json'),'utf8'));
    assert.equal(stored.freshness,undefined,'reading never rewrites historical observations');
  }finally{await fs.rm(dir,{recursive:true,force:true});}
});

test('resource inventory distinguishes missing sources, exports and changed revisions without writing', async () => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(),'sf-resources-'));
  try {
    const project = {name:'Mi video', sources:{camera:{path:'raw/camera.mov',screen:{path:'raw/screen.mp4'}}}};
    await fs.mkdir(path.join(dir,'raw'));
    await fs.mkdir(path.join(dir,'renders'));
    await fs.writeFile(path.join(dir,'raw/camera.mov'),'camera');
    await fs.writeFile(path.join(dir,'renders/test.mp4'),'export');
    await fs.writeFile(path.join(dir,'project.json'),JSON.stringify(project));
    const before = await fs.readdir(dir);
    const first = await projectResources(dir);
    assert.equal(first.name,'Mi video');
    assert.equal(first.resources.find(r=>r.label==='camera').state,'available');
    assert.equal(first.resources.find(r=>r.label==='camera · pantalla').state,'missing');
    assert.equal(first.resources.filter(r=>r.kind==='export').length,1);
    assert.equal(await resolveResource(dir,first.resources.find(r=>r.label==='camera').id),await fs.realpath(path.join(dir,'raw/camera.mov')));
    assert.equal(await resolveResource(dir,'../../private'),null);
    assert.equal(await resolveResource(dir,first.resources.find(r=>r.label==='camera · pantalla').id),null);
    assert.deepEqual(await fs.readdir(dir),before);
    project.name = 'Nueva revisión';
    await fs.writeFile(path.join(dir,'project.json'),JSON.stringify(project));
    const second = await projectResources(dir);
    assert.notEqual(first.revision,second.revision);
    assert.equal(first.resources[0].id,second.resources[0].id);
    await fs.writeFile(path.join(dir,'project.json'),'{bad');
    assert.equal((await projectResources(dir)).error,'project.json ilegible');
  } finally { await fs.rm(dir,{recursive:true,force:true}); }
});

test('modern projects without publication appear; dossier reads do not write', async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(),'sf-gallery-'));
  try {
    const project = path.join(root,'recording'); await fs.mkdir(project);
    await fs.writeFile(path.join(project,'project.json'),'{}');
    const input = {roots:[root],project};
    const list = await query({...input,action:'list'});
    assert.equal(list.items.length,1);
    assert.equal(list.items[0].launch.key,'edicion');
    assert.equal((await query({...input,action:'publish'})).found,false);
    const before = await fs.readdir(project);
    const detail = await query({...input,action:'item',id:list.items[0].id});
    assert.equal(detail.description,'');
    assert.deepEqual(await fs.readdir(project),before);
    await assert.rejects(query({...input,action:'item',id:'r0/../secrets'}));
  } finally { await fs.rm(root,{recursive:true,force:true}); }
});

test('thumbnail symlinks cannot expose files outside the project', async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(),'sf-thumb-'));
  try {
    const project = path.join(root,'recording'); await fs.mkdir(path.join(project,'thumbs'),{recursive:true});
    await fs.writeFile(path.join(project,'project.json'),'{}');
    await fs.writeFile(path.join(root,'private.png'),'secret');
    await fs.symlink(path.join(root,'private.png'),path.join(project,'thumbs','escape.png'));
    await assert.rejects(query({roots:[root],project,action:'thumb',id:'r0/recording',file:'escape.png'}),/fuera/);
  } finally { await fs.rm(root,{recursive:true,force:true}); }
});


test('creative direction and actual plans are discoverable without implying approval', async()=>{
 const dir=await fs.mkdtemp(path.join(os.tmpdir(),'sf-direction-'));
 try {
  await fs.mkdir(path.join(dir,'design'));
  await fs.writeFile(path.join(dir,'project.json'),'{}');
  await fs.writeFile(path.join(dir,'design/direccion.json'),'{}');
  await fs.writeFile(path.join(dir,'design/plan-v42.md'),'Decisiones');
  await fs.writeFile(path.join(dir,'design/credentials.txt'),'not a resource');
  const inventory=await projectResources(dir);
  const design=inventory.resources.filter(r=>r.kind==='design');
  assert.equal(design.length,2);
  assert.equal(design.some(r=>r.label.includes('v42')),true);
  assert.equal(inventory.resources.some(r=>r.path.endsWith('credentials.txt')),false);
  assert.equal(await resolveResource(dir,design[0].id),await fs.realpath(path.join(dir,'design/direccion.json')));
 }finally{await fs.rm(dir,{recursive:true,force:true});}
});


test('gallery patch persists, rejects stale/missing revisions, never publishes, and serializes writers',async()=>{
 const root=await fs.mkdtemp(path.join(os.tmpdir(),'sf-patch-'));
 const dir=path.join(root,'project');await fs.mkdir(dir);
 try {
  await fs.writeFile(path.join(dir,'publish.json'),JSON.stringify({video:{titulo:'Inicial'},data:{post_draft:{body:'Borrador',approved_at:null},launch:{publish_at:'2030-01-01'}}}));
  const input={project:dir,roots:[root],id:'r0/project'};
  const before=await query({...input,action:'item'});
  await assert.rejects(query({...input,action:'patch',patch:{titulo:'Sin revisión'}}),/revisión/);
  const saved=await query({...input,action:'patch',patch:{publication_revision:before.publication_revision,description:'Texto revisado'}});
  assert.equal(saved.item.description,'Texto revisado');
  assert.notEqual(saved.item.publication_revision,before.publication_revision);
  await assert.rejects(query({...input,action:'patch',patch:{publication_revision:before.publication_revision,titulo:'Obsoleto'}}),/cambió/);
  const again=await query({...input,action:'item'});
  assert.equal(again.titulo,'Inicial');assert.equal(again.description,'Texto revisado');
  assert.equal(again.post.approved_at,null);assert.equal(again.launch_data.publish_at,'2030-01-01');
  const results=await Promise.allSettled(['A','B'].map(titulo=>query({...input,action:'patch',patch:{publication_revision:again.publication_revision,titulo}})));
  assert.equal(results.filter(r=>r.status==='fulfilled').length,1);
  assert.equal((await fs.readdir(dir)).includes('.gallery-write.lock'),false);
 }finally{await fs.rm(root,{recursive:true,force:true});}
});


test('history invalidates standards, engine and source replacements without rewriting the record',async()=>{
 const dir=await fs.mkdtemp(path.join(os.tmpdir(),'sf-inputs-'));
 try {
  await fs.writeFile(path.join(dir,'source.mov'),'first');
  await fs.writeFile(path.join(dir,'project.json'),JSON.stringify({sources:{camera:{path:'source.mov'}}}));
  for(const file of ['standard.md','engine.py','proof.txt'])await fs.writeFile(path.join(dir,file),'original');
  const run=await recordRun(dir,{summary:'Control de entradas',standard_revision:'fixture',standard_files:['standard.md'],motor_files:['engine.py'],result:'passed',evidence:['proof.txt']});
  assert.equal((await readRuns(dir))[0].freshness,'matching');
  await fs.writeFile(path.join(dir,'standard.md'),'new rule');
  assert.ok((await readRuns(dir))[0].invalidation_reasons.includes('cambió el estándar'));
  await fs.writeFile(path.join(dir,'engine.py'),'new engine');
  await fs.writeFile(path.join(dir,'source.mov'),'replacement video');
  const current=(await readRuns(dir))[0];
  assert.ok(current.invalidation_reasons.includes('cambió el motor'));
  assert.ok(current.invalidation_reasons.includes('cambió un medio'));
  const disk=JSON.parse(await fs.readFile(path.join(dir,'.sfstudio/runs',run.id+'.json')));
  assert.equal(disk.result,'passed');assert.equal(disk.freshness,undefined);
 }finally{await fs.rm(dir,{recursive:true,force:true});}
});
