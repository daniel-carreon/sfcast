import {promises as fs} from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import {createHash} from 'node:crypto';
const brain=()=>process.env.ARTIFICIAL_BRAIN_ROOT || path.join(os.homedir(),'Developer/artificial-brain');
export async function smallDigest(file) {
 const stat=await fs.stat(file);
 if(!stat.isFile() || stat.size>8*1024*1024)throw new Error('Reporte fuera del límite de 8 MB');
 return createHash('sha256').update(await fs.readFile(file)).digest('hex');
}
// Code and standards are content-hashed. Large media uses an explicitly weaker stat signature.
export async function inputsFor(project,{standard_files,motor_files}={}) {
 const skill=path.join(brain(),'.claude/skills/edicion-de-video');
 const standards=standard_files || ['SKILL.md','references/estandar.md','references/direccion-creativa.md','references/sound-design.md'].map(f=>path.join(skill,f));
 const motors=motor_files || ['sala/bridge.py','motor/timeline.py','motor/render_base.py','motor/compose.py','sala/preview_movie.py','motor/score.py','motor/synced_sources.py'].map(f=>path.join(skill,'scripts',f));
 const entries=[];
 for(const [role,files] of [['standard',standards],['motor',motors]]) for(const file of files) {
  const absolute=path.resolve(project,file);
  entries.push({role,path:absolute,method:'sha256',value:await smallDigest(absolute)});
 }
 const direction=path.join(project,'design/direccion.json');
 try {entries.push({role:'direction',path:direction,method:'sha256',value:await smallDigest(direction)});}
 catch(e){if(e.code!=='ENOENT')throw e;}
 const doc=JSON.parse(await fs.readFile(path.join(project,'project.json'),'utf8').catch(e=>{if(e.code==='ENOENT')return '{}';throw e;}));
 const media=new Set();
 for(const source of Object.values(doc.sources || {})) for(const file of [source.path,source.audio_path,source.screen?.path])if(file)media.add(path.resolve(project,file));
 for(const item of [...(doc.events || []),...(doc.score?.cues || [])])if(item.asset && !item.asset.includes('{'))media.add(path.resolve(project,item.asset));
 for(const file of media) entries.push({role:'media',path:file,method:'stat',value:await mediaSignature(file)});
 return entries;
}
export async function mediaSignature(file) {
 const st=await fs.stat(file);if(!st.isFile())throw new Error('Fuente no es archivo');
 return `${st.size}:${st.mtimeMs}:${st.ctimeMs}`;
}
export async function invalidInputs(entries) {
 const reasons=[];
 for(const item of entries || []) {
  try {
   const value=item.method==='sha256'?await smallDigest(item.path):item.method==='stat'?await mediaSignature(item.path):null;
   if(value!==item.value)reasons.push(`cambió ${item.role==='standard'?'el estándar':item.role==='motor'?'el motor':item.role==='direction'?'la dirección creativa':'un medio'}`);
  }catch{reasons.push(`falta entrada de ${item.role}`);}
 }
 return reasons;
}
