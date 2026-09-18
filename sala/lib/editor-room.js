import { promises as fs } from 'node:fs';
import path from 'node:path';

/** A handle locates a candidate; live health must confirm it before showing a link. */
export async function editorRoom(project) {
  let handle;
  try {handle=JSON.parse(await fs.readFile(path.join(project,'sala-handle.json'),'utf8'));}
  catch{return {state:'closed',reason:'No hay una sala registrada para este proyecto.'};}
  if(!Number.isInteger(handle.port)||handle.port<1||handle.port>65535||!Number.isInteger(handle.pid))
    return {state:'invalid',reason:'El registro de la sala es inválido.'};
  const url=`http://127.0.0.1:${handle.port}`;
  try {
    const response=await fetch(url+'/api/health',{signal:AbortSignal.timeout(1200)});
    const health=await response.json();
    if(!response.ok || health.ok!==true || health.pid!==handle.pid)
      return {state:'stale',reason:'El puerto ya no corresponde al proceso registrado.'};
    if(health.project && await fs.realpath(health.project)!==await fs.realpath(project))
      return {state:'stale',reason:'La sala abierta pertenece a otro proyecto.'};
    return {state:'live',url,pid:handle.pid,verified_at:new Date().toISOString(),
      identity_check:health.project?'project-and-process':'legacy-process',section:handle.section||null};
  }catch{return {state:'closed',reason:'La sala registrada no responde.'};}
}
