import { promises as fs } from 'node:fs';
import path from 'node:path';
import { randomUUID, createHash } from 'node:crypto';
import {inputsFor,invalidInputs,smallDigest} from './history-inputs.js';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
async function privateDir(project) {
  const root = await fs.realpath(project);
  const dir = path.join(root,'.sfstudio');
  await fs.mkdir(dir,{recursive:true});
  if (await fs.realpath(dir) !== dir) throw new Error('.sfstudio no puede ser un enlace');
  return dir;
}
async function exclusiveJson(file,value) {
  const temp = file + '.' + randomUUID() + '.tmp';
  await fs.writeFile(temp,JSON.stringify(value,null,2)+'\n',{flag:'wx'});
  try { await fs.link(temp,file); } finally { await fs.unlink(temp); }
}
export async function readIdentity(project) {
  try {
    const x = JSON.parse(await fs.readFile(path.join(project,'.sfstudio','identity.json'),'utf8'));
    if (x.version !== 1 || !UUID.test(x.id) || (x.parent_id && !UUID.test(x.parent_id))) throw new Error('Identidad inválida');
    return x;
  } catch(e) { if(e.code === 'ENOENT') return null; throw e; }
}
export async function initIdentity(project,{parent_id=null,channel='youtube'}={}) {
  if(parent_id && !UUID.test(parent_id)) throw new Error('parent_id inválido');
  if(!['youtube','instagram'].includes(channel)) throw new Error('Canal inválido');
  const existing = await readIdentity(project);
  if(existing) return existing;
  const dir = await privateDir(project);
  const value={version:1,id:randomUUID(),parent_id,channel,created_at:new Date().toISOString()};
  try {await exclusiveJson(path.join(dir,'identity.json'),value);}
  catch(e){if(e.code!=='EEXIST')throw e;}
  return readIdentity(project);
}
export async function revisionOf(project) {
  for(const name of ['project.json','timeline.json']) {
    try {return {file:name,sha256:hash(await fs.readFile(path.join(project,name))) };}
    catch(e){if(e.code!=='ENOENT')throw e;}
  }
  return null;
}
// Explicit agent operation. A read of the gallery never creates history or passes a gate.
export async function recordRun(project,input) {
  if(!input.summary || !input.standard_revision || !['passed','failed','pending'].includes(input.result))
    throw new Error('Se requiere resumen, revisión del estándar y resultado explícito');
  const creative_checks=input.creative_checks || [];
  const allowed=new Set(['intro_in_motion','face_clear','mobile_legibility','audio_sync','reference_comparison','preview_cta']);
  if(!Array.isArray(creative_checks) || creative_checks.some(c=>!allowed.has(c.id) || !['structural','visual','perceptual'].includes(c.method) || typeof c.scope!=='string' || !c.scope.trim()))
    throw new Error('Comprobación creativa requiere id, método y alcance explícitos');
  if(creative_checks.length && !input.evidence?.length)throw new Error('Comprobación creativa requiere reporte de evidencia');
  const identity=await initIdentity(project);
  const revision=await revisionOf(project);
  if(!revision)throw new Error('Sin proyecto editable');
  const root=await fs.realpath(project);
  const evidence=[];
  for(const relative of input.evidence || []) {
    const file=await fs.realpath(path.resolve(project,relative));
    if(!file.startsWith(root+path.sep))throw new Error('Evidencia fuera del proyecto');
    const stat=await fs.stat(file);
    if(!stat.isFile() || stat.size>8*1024*1024)throw new Error('Usa un reporte de evidencia de hasta 8 MB');
    evidence.push({path:path.relative(root,file),sha256:hash(await fs.readFile(file))});
  }
  if(input.result==='passed' && !evidence.length)throw new Error('Un resultado aprobado exige evidencia');
  const inputs=await inputsFor(project,input);
  const run={version:2,inputs,creative_checks,id:randomUUID(),project_id:identity.id,at:new Date().toISOString(),revision,
    standard_revision:input.standard_revision,summary:input.summary,result:input.result,evidence};
  const dir=path.join(await privateDir(project),'runs');await fs.mkdir(dir,{recursive:true});
  if(await fs.realpath(dir)!==dir)throw new Error('runs no puede ser un enlace');
  await exclusiveJson(path.join(dir,run.id+'.json'),run);
  return run;
}
export async function readRuns(project) {
  const revision=await revisionOf(project);
  const dir=path.join(project,'.sfstudio','runs');
  let files;try{files=await fs.readdir(dir);}catch(e){if(e.code==='ENOENT')return [];throw e;}
  const runs=[];
  for(const file of files.filter(f=>f.endsWith('.json'))) {
    try {
      const run=JSON.parse(await fs.readFile(path.join(dir,file),'utf8'));
      const reasons=await invalidInputs(run.inputs);
      const identity=await readIdentity(project);
      if(run.project_id!==identity?.id)reasons.push('el registro pertenece a otro proyecto');
      if(run.revision?.sha256!==revision?.sha256)reasons.push('cambió el proyecto');
      for(const item of run.evidence || []) {
        try {
          const root=await fs.realpath(project), target=await fs.realpath(path.resolve(project,item.path));
          if(!target.startsWith(root+path.sep) || await smallDigest(target)!==item.sha256)reasons.push('cambió la evidencia');
        }catch{reasons.push('falta evidencia');}
      }
      runs.push({...run,coverage:run.version===2?'proyecto, evidencia, estándar, motor y firma stat de medios':'histórico: proyecto y evidencia; entradas no registradas',freshness:reasons.length?'invalidated':'matching',invalidation_reasons:[...new Set(reasons)]});
    }catch{runs.push({id:file,result:'pending',freshness:'unreadable',summary:'Registro ilegible'});}
  }
  return runs.sort((a,b)=>(b.at||'').localeCompare(a.at||''));
}
