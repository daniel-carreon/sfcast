#!/usr/bin/env node
// Shared gallery contract. Reads are inert; patch is an explicit guarded mutation.
import path from 'node:path';
import { promises as fs } from 'node:fs';
import { defaultRoots, scanRoots, resolveId, readCard, readDossier, resolveThumb, applyGalleryPatch } from '../lib/gallery.js';
import { loadPublish, STAGES, STAGE_COMMANDS } from '../lib/publish.js';
import { resolveResource } from '../lib/project-resources.js';
import { workflow, graphFile } from '../lib/workflow.js';

export async function query(input) {
  const roots = input.roots || defaultRoots();
  const project = path.resolve(input.project);
  if(input.action==='workflow')return workflow();
  if(input.action==='graph-file')return {file:await graphFile(input.file)};
  if (input.action === 'publish') {
    const pub = await loadPublish(project);
    return { found: !!pub, project, stages: STAGES, commands: STAGE_COMMANDS, ...(pub ? {publish: pub} : {}) };
  }
  const entries = await scanRoots(roots);
  if (input.action === 'list') {
    const items = await Promise.all(entries.map(async e => {
      try { return await readCard(e); }
      catch (err) { return { id:e.id, name:e.name, error:err.message }; }
    }));
    items.sort((a,b) => (b.updated_at || '').localeCompare(a.updated_at || '') || a.name.localeCompare(b.name));
    return {roots, count:items.length, items, open:project};
  }
  const entry = entries.find(e => e.id === input.id || e.legacy_id === input.id);
  if (!entry) throw new Error('Proyecto no encontrado');
  // A project symlink must not escape the configured root.
  const real = await fs.realpath(entry.dir);
  const root = await fs.realpath(entry.root);
  const relative = path.relative(root,real);
  if (relative.startsWith('..') || path.isAbsolute(relative)) throw new Error('Proyecto fuera de raíz');
  if (input.action === 'item') return readDossier(entry);
  if (input.action === 'patch') {
    if(typeof input.patch?.publication_revision!=='string')throw new Error('Recarga la ficha antes de guardar: falta revisión');
    const {changed}=await applyGalleryPatch(entry.dir,input.patch);
    return {ok:true,changed,item:await readDossier(entry)};
  }
  if (input.action === 'resource') {
    const file = await resolveResource(entry.dir,input.resource);
    if (!file) throw new Error('Recurso no disponible');
    return {file};
  }
  if (input.action === 'thumb') {
    const file = await resolveThumb(entry.dir,input.file);
    if (!file) throw new Error('Miniatura no encontrada');
    const target = await fs.realpath(file);
    if (!target.startsWith(real + path.sep)) throw new Error('Miniatura fuera del proyecto');
    return {file:target};
  }
  throw new Error('Acción desconocida');
}

if (process.argv[1] === new URL(import.meta.url).pathname) {
  try {
    let body = '';
    for await (const chunk of process.stdin) body += chunk;
    process.stdout.write(JSON.stringify(await query(JSON.parse(body))));
  } catch (error) {
    process.stdout.write(JSON.stringify({error:error.message}));
    process.exitCode = 1;
  }
}
