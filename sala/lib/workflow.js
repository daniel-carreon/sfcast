import { promises as fs } from 'node:fs';
import path from 'node:path';
import os from 'node:os';

// Presentation groups reference canonical node IDs. They do not define execution order.
export const stages = [
  {id:'material',label:'Material',question:'¿Con qué empezamos?',nodes:['estructura','raw','reloj'],kinds:['source']},
  {id:'corte',label:'Corte',question:'¿Qué merece quedarse?',nodes:['transcript_raw','edl','guion_corte'],kinds:['cut']},
  {id:'diseno',label:'Diseño',question:'¿Cómo hacemos visible la idea?',nodes:['canon','alternativas','design_map','evidencia','imagenes','cards','captions','sonido'],kinds:['design']},
  {id:'revision',label:'Revisión',question:'¿Lo que vemos cumple lo decidido?',nodes:['timeline','preview','sala','notas','reglas'],kinds:['project','timeline','verification']},
  {id:'entrega',label:'Entrega',question:'¿Qué versión recibe la audiencia?',nodes:['master','publicacion','metricas_api','instagram'],kinds:['export','publication']},
];
function root() { return path.join(process.env.ARTIFICIAL_BRAIN_ROOT || path.join(os.homedir(),'Developer/artificial-brain'),'arbrain/public/conectoma'); }
export async function graphFile(name) {
  if(!['index.html','style.css','app.js','dagre.min.js','grafos/edicion-de-video.json'].includes(name))throw new Error('Archivo de grafo no permitido');
  return path.join(root(),name);
}
export async function workflow() {
  const graph=JSON.parse(await fs.readFile(await graphFile('grafos/edicion-de-video.json'),'utf8'));
  const ids=new Set(graph.nodos.map(n=>n.id));
  for(const stage of stages) for(const id of stage.nodes) if(!ids.has(id))throw new Error(`Recorrido desactualizado: falta ${id}`);
  return {graph,stages};
}
