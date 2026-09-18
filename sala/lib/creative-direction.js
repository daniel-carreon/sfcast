import {promises as fs} from 'node:fs';
import path from 'node:path';
const choices={logos:'Logos',evidence:'Demostraciones y referencias',generated_images:'Imágenes generadas',code_animation:'Animación',depth_3d:'Profundidad 3D',sound:'Sonido'};
const reviews={intro_in_motion:'Intro en movimiento',face_clear:'Rostro libre',mobile_legibility:'Lectura móvil',audio_sync:'Sincronía',reference_comparison:'Comparación con referente',preview_cta:'Presencia en preview y CTA'};
export function projectDirection(doc, runs=[]){
 const decisions=Object.entries(choices).map(([id,label])=>{
  const value=doc?.intro?.[id];const reason=typeof value?.reason==='string'?value.reason.trim():'';
  return {id,label,reason,status:reason&&typeof value?.use==='boolean'?(value.use?'planned':'excluded'):'pending'};
 });
 const checks=Object.entries(reviews).map(([id,label])=>{
  const value=doc?.review?.[id];const evidence=typeof value?.evidence==='string'?value.evidence.trim():'';
  const verification=runs.flatMap(run=>(run.creative_checks || []).filter(c=>c.id===id).map(c=>({
   run_id:run.id,method:c.method,scope:c.scope,result:run.result,
   freshness:run.inputs?.some(i=>i.role==='direction')?run.freshness:'unbound',
   reasons:run.invalidation_reasons || [],evidence:run.evidence || []
  })));
  return {id,label,evidence,status:value?.checked===true&&evidence?'reported':'pending',verification};
 });
 return {standard:doc?.standard||null,intent:doc?.intro?.intent||'',reason:doc?.selected_reason||'',decisions,checks,
  artistic_approval:doc?.artistic_approval===true,
  scope:'Declaraciones de dirección. Los textos de revisión no prueban vigencia frente al montaje actual; contrastar con el historial y el render.'};
}
export async function creativeDirection(dir,runs=[]){
 const root=await fs.realpath(dir);const file=path.join(root,'design/direccion.json');
 try{
  const real=await fs.realpath(file);
  if(!real.startsWith(root+path.sep))throw new Error('Dirección fuera del proyecto');
  const stat=await fs.stat(real);if(stat.size>1024*1024)throw new Error('Dirección demasiado grande');
  return {state:'available',...projectDirection(JSON.parse(await fs.readFile(real,'utf8')),runs)};
 }catch(e){
  return {state:e.code==='ENOENT'?'missing':'invalid',message:e.code==='ENOENT'?'Falta registrar dirección creativa.':'No se pudo interpretar la dirección creativa.',...projectDirection(null)};
 }
}
