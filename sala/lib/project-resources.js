// Read-only inventory. Existence is not approval, export parity or artistic validation.
import { promises as fs } from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { readIdentity, readRuns } from './project-history.js';

export async function projectResources(dir) {
  let project = null;
  let revision = null;
  let error = null;
  try {
    const raw = await fs.readFile(path.join(dir, 'project.json'));
    revision = createHash('sha256').update(raw).digest('hex');
    project = JSON.parse(raw);
  } catch (e) { if (e.code !== 'ENOENT') error = 'project.json ilegible'; }
  const resources = [];
  async function add(kind, label, file, declaredBy, optional = false) {
    if (typeof file !== 'string' || !file) return;
    const absolute = path.resolve(dir, file);
    let stat;
    try { stat = await fs.stat(absolute); } catch { /* absence is an explicit state */ }
    if (optional && !stat?.isFile()) return;
    resources.push({ id: createHash('sha256').update(kind + '\0' + absolute).digest('hex').slice(0,24),
      kind, label, path: absolute, declared_by: declaredBy,
      state: stat?.isFile() ? 'available' : 'missing',
      bytes: stat?.isFile() ? stat.size : null,
      modified_at: stat?.isFile() ? stat.mtime.toISOString() : null });
  }
  await add('project','Proyecto editable','project.json','project.json',true);
  await add('timeline','Timeline histórica','timeline.json','timeline.json',true);
  for (const [name, source] of Object.entries(project?.sources || {})) {
    await add('source', name, source.path, `project.json:sources.${name}.path`);
    if (source.audio_path && source.audio_path !== source.path)
      await add('source', `${name} · audio`, source.audio_path, `project.json:sources.${name}.audio_path`);
    await add('source', `${name} · pantalla`, source.screen?.path, `project.json:sources.${name}.screen.path`);
  }
  await add('cut','Decisiones de corte',project?.editorial_source,'project.json:editorial_source');
  for (const [file,label] of [['publish.json','Paquete de publicación'],['DESCRIPCION-youtube.txt','Descripción'],['post-comunidad.md','Borrador de comunidad']])
    await add('publication',label,file,file,true);
  let delivery=null;
  try {
    const pub=JSON.parse(await fs.readFile(path.join(dir,'publish.json'),'utf8'));
    const receipt=pub.data?.youtube?.source_file;
    const vid=pub.data?.youtube?.video_id || pub.video?.youtube_id;
    if(receipt?.video_id===vid && receipt?.basis==='completed-resumable-session' && typeof receipt.path==='string' && receipt.path.trim() && Number.isSafeInteger(receipt.bytes) && receipt.bytes>=0 && /^[a-f0-9]{64}$/.test(receipt.sha256)){
      await add('publication','Máster registrado de la subida',receipt.path,'publish.json:data.youtube.source_file');
      const resource=resources.at(-1);
      delivery={video_id:vid,resource_id:resource.id,recorded_sha256:receipt.sha256,recorded_bytes:receipt.bytes,
        state:resource.state==='missing'?'missing':resource.bytes!==receipt.bytes?'changed':'recorded',
        scope:'Recibo del transporte completado. El catálogo no recalcula el hash del archivo ni certifica la aprobación artística.'};
    }
  }catch(e){if(e.code!=='ENOENT')error=error || 'Paquete de publicación ilegible';}
  await add('design','Dirección creativa','design/direccion.json','design/direccion.json',true);
  // Index the actual plans without pretending that the newest filename is approved.
  try {
    for (const file of (await fs.readdir(path.join(dir,'design'))).sort())
      if (/^plan(?:-[a-zA-Z0-9_-]+)?\.md$/.test(file))
        await add('design',`Plan · ${file}`,path.join('design',file),'design/',true);
  } catch { /* no direction artifacts yet */ }
  // Explicit media export folder only; never recursively expose arbitrary project files.
  try {
    for (const file of (await fs.readdir(path.join(dir,'renders'))).sort())
      if (/\.(mp4|mov|webm)$/i.test(file)) await add('export',file,path.join('renders',file),'renders/',true);
  } catch { /* no export folder */ }
  let identity=null,history=[];
  try {identity=await readIdentity(dir);history=await readRuns(dir);}catch(e){error=error || e.message;}
  for(const run of history)for(const report of run.evidence || [])
    await add('verification',`${run.summary} · ${path.basename(report.path)}`,report.path,`run:${run.id}`);
  return { revision, identity, history, delivery, name: project?.name || null, error, resources,
    graph: { slug:'edicion-de-video' },
    pending: Array.isArray(project?.pending) ? project.pending : [],
    requirements: project?.review?.presence_contract || null };
}

/** Resolve an inventory token, never a client supplied path. Original media may live on SSD. */
export async function resolveResource(dir, id) {
  const inventory = await projectResources(dir);
  const resource = inventory.resources.find(r => r.id === id && r.state === 'available');
  if (!resource) return null;
  const real = await fs.realpath(resource.path);
  const root = await fs.realpath(dir);
  const inside = real.startsWith(root + path.sep);
  const media = /\.(mov|mp4|webm|m4v|wav|mp3|m4a|aac|flac)$/i;
  if (resource.kind === 'source') {
    if (!media.test(real) || !media.test(resource.path)) return null;
  } else if (!inside) return null;
  return real;
}
