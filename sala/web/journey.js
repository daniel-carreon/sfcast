const $=id=>document.getElementById(id);
const esc=x=>String(x??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const id=new URLSearchParams(location.search).get('project');
let data,item,selected=0;
async function get(url){const r=await fetch(url);const j=await r.json();if(!r.ok||j.error)throw new Error(j.error||'No disponible');return j;}
function verificationDetails(check){
 const methods={structural:'Estructura',visual:'Inspección visual',perceptual:'Revisión perceptual'};
 const states={matching:'Entradas coincidentes',invalidated:'Revisar de nuevo',unbound:'Sin vínculo a esta dirección'};
 return (check.verification||[]).map(v=>`<p><strong>${esc(methods[v.method]||v.method)} · ${esc(states[v.freshness]||v.freshness)}</strong><br>${esc(v.scope)}<br>Resultado registrado: ${esc(v.result)}</p>${v.reasons.length?`<p>${esc(v.reasons.join('; '))}</p>`:''}${v.evidence.map(e=>{
  const r=item.production.resources.find(r=>r.declared_by==='run:'+v.run_id && r.path.endsWith('/'+e.path));
  return r?.state==='available'?`<p><a target="_blank" rel="noopener" href="/gallery/resource?id=${encodeURIComponent(item.id)}&resource=${encodeURIComponent(r.id)}">Ver reporte ↗</a></p>`:'';
 }).join('')}`).join('');
}
function creativePanel(){
 const c=item?.creative;if(!c)return '';
 const labels={planned:'Previsto',excluded:'Descartado con razón',pending:'Pendiente',reported:'Revisión declarada'};
 return `<section class="creative"><h3>Decisiones de este video</h3><p>${esc(c.reason||c.message||'Sin dirección registrada')}</p>
 ${c.decisions.map(d=>`<details><summary>${esc(d.label)} <span class="decision-state">${labels[d.status]}</span></summary><p>${esc(d.reason||'Falta resolver su aplicación a este video.')}</p></details>`).join('')}
 <h3>Revisión y límites</h3>${c.checks.map(d=>`<details><summary>${esc(d.label)} <span class="decision-state">${labels[d.status]}</span></summary><p>${esc(d.evidence||'Sin revisión visual o perceptual declarada.')}</p>${verificationDetails(d)}</details>`).join('')}
 <p class="journeyNote">${esc(c.scope)}</p><p>Aprobación artística registrada: ${c.artistic_approval?'sí':'no'}.</p></section>`;
}
function render(){
  const stage=data.stages[selected];
  $('stages').innerHTML=data.stages.map((s,i)=>`<button data-index="${i}" ${i===selected?'aria-current="step"':''}><span>0${i+1}</span>${esc(s.label)}</button>`).join('');
  const nodes=data.graph.nodos.filter(n=>stage.nodes.includes(n.id));
  const resources=(item?.production?.resources||[]).filter(r=>stage.kinds.includes(r.kind));
  const loops=data.graph.lazos.filter(l=>stage.nodes.some(n=>l.sobre===`nodo:${n}`));
  $('detail').innerHTML=`<div><h2>${esc(stage.question)}</h2>${selected===2?creativePanel():''}<details><summary>Explorar el método</summary>${nodes.map(n=>`<details><summary>${esc(n.label)}</summary><p>${esc(n.resumen||n.desc)}</p><details><summary>Detalle técnico</summary><small>${esc(n.desc||n.ruta||'Sin detalle adicional')}</small></details></details>`).join('')}</details></div>
    <div class="evidence"><h3>En este video</h3><ul>${resources.map(r=>`<li>${r.state==='available'?`<a target="_blank" rel="noopener" href="/gallery/resource?id=${encodeURIComponent(item.id)}&resource=${encodeURIComponent(r.id)}">${esc(r.label)} ↗</a>`:esc(r.label)}<small>${r.state==='available'?'Archivo disponible':'Archivo ausente'}</small></li>`).join('')||'<li>No hay recursos vinculados a esta etapa todavía.</li>'}</ul>
    ${selected===3?`${item?.editor?.state==='live'?`<p><a target="_blank" rel="noopener" href="${esc(item.editor.url)}">Abrir en el editor ↗</a></p>`:`<p>${esc(item?.editor?.reason||'Sin sala activa')}</p>`}<h3>Comprobaciones registradas</h3><ul>${(item?.production?.history||[]).map(r=>`<li>${esc(r.summary)}<small>${esc(r.result)} · ${esc(r.freshness)}</small></li>`).join('')||'<li>Sin comprobaciones registradas.</li>'}</ul><button class="return" id="demoReturn">Mostrar cómo vuelve una corrección</button><p id="demoNote" class="journeyNote">Demostración del lazo. No modifica el video.</p>`:''}
    ${loops.length?`<h3>Qué se compara</h3>${loops.map(l=>`<details><summary>${esc(l.label)}</summary><p>${esc(l.resumen)}</p><small>${esc(l.comparador)}</small></details>`).join('')}`:''}
    ${selected===4?`<p>Publicación: ${esc(item?.launch?.label||'sin evidencia')}</p>`:''}</div>`;
  $('demoReturn')?.addEventListener('click',()=>{selected=2;render();$('detail').insertAdjacentHTML('afterbegin','<p class="journeyNote">Demostración: una observación de revisión devuelve el trabajo a Diseño. Corregir exige después volver a comprobar.</p>');});
  history.replaceState(null,'',location.pathname+location.search+'#'+stage.id);
}
$('stages').addEventListener('click',e=>{const b=e.target.closest('button[data-index]');if(b){selected=Number(b.dataset.index);render();}});
try{
  [data,item]=await Promise.all([get('/api/workflow'),id?get('/api/gallery/item?id='+encodeURIComponent(id)):Promise.resolve(null)]);
  $('projectName').textContent=item?.titulo || 'Método general · selecciona un video en la galería para ver su evidencia.';
  $('back').href='/'+(item?'#project='+encodeURIComponent(item.id):'');
  selected=Math.max(0,data.stages.findIndex(s=>s.id===location.hash.slice(1)));render();
}catch(e){$('projectName').textContent='No se pudo cargar el recorrido: '+e.message;}
