const $ = id => document.getElementById(id);
const esc = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const pct = value => `${Math.round((value || 0) * 100)}%`;
const elapsed = ms => ms == null ? '-' : ms < 1000 ? `${ms}ms` : `${(ms / 1000).toFixed(1)}s`;
const humanize = value => String(value ?? '').replace(/-v\d+$/,'').replaceAll('-',' ').replace(/^./,c=>c.toUpperCase());
const sourceLabel = value => ({new_source:'New candidate source',known_lesson_source:'Reused qualified source',no_source:'Invalid / no source'}[value]||humanize(value));
let contractsLoaded = false;
const coachFeatures = [
  ['catalog','Catalog'],['search-filter-sort','Search / filter / sort'],['contact-form','Contact form'],
  ['registration','Registration'],['account-settings','Account settings'],['workflow','Workflow'],
  ['persistent-data','Persistent state'],['dialogs','Dialogs'],['keyboard-accessibility','Keyboard access'],
  ['analytics','Analytics'],['responsive-navigation','Responsive navigation'],
];
$('featureChecks').innerHTML=coachFeatures.map(([id,label])=>`<label><input type="checkbox" value="${id}">${label}</label>`).join('');

function summarizeDetail(detail) {
  let text = String(detail ?? '').replace(/\u001b\[[0-9;]*m/g, '');
  if (/unique ["']key["'] prop/i.test(text)) return 'React list in App is missing unique key props.';
  const waiting = text.match(/waiting for (.+?)(?: to be visible)?\s*$/im);
  if (/Timeout \d+ms exceeded/i.test(text) && waiting) return `Missing ${waiting[1].trim()}`;
  text = text.replace(/Call log:[\s\S]*$/i, '').replace(/See https:\S+/g, '').replace(/%s/g, '');
  const actual = text.split(/\bActual:\s*/i)[1];
  if (actual) {
    const rest = summarizeDetail(actual);
    const hint = text.split(/\bActual:\s*/i)[0].replace(/\s+/g, ' ').trim();
    return hint ? `${hint} Actual: ${rest}` : rest;
  }
  return text.replace(/\s+/g, ' ').trim().slice(0, 220);
}

function formatFeedback(raw) {
  if (!raw) return '';
  try {
    const rows = JSON.parse(raw);
    if (!Array.isArray(rows)) return String(raw);
    return rows.map(row => {
      const seen = new Set();
      const checks = [];
      for (const check of row.failedChecks || []) {
        if (seen.has(check.name)) continue;
        seen.add(check.name);
        checks.push(`${check.name}: ${summarizeDetail(check.detail)}`);
      }
      const checkBlob = checks.join('\n').toLowerCase();
      const errors = (row.errors || []).filter(error => {
        const text = summarizeDetail(error).toLowerCase();
        return text && !checkBlob.includes(text) && ![...seen].some(name => text.includes(name));
      });
      return [row.split ? `[${row.split}]` : '', ...checks, ...errors].filter(Boolean).join('\n');
    }).filter(Boolean).join('\n\n');
  } catch {
    return String(raw);
  }
}

function bars(rows, bad = false) {
  if (!rows.length) return '<p class="meta">No evidence yet.</p>';
  const max = Math.max(...rows.map(row => row.value), 1);
  return rows.map(row => `<div class="bar-row ${bad ? 'bad' : ''}"><span>${esc(row.label)}</span><div class="bar"><i style="width:${Math.max(2,row.value/max*100)}%"></i></div><strong>${esc(row.display ?? row.value)}</strong></div>`).join('');
}

function render(data) {
  const live=['generating','evaluating','learning','consulting_tutor'].includes(data.status);
  const armed=Boolean(data.trainingPaused && live);
  $('status').textContent = armed
    ? (data.trainingStopQwen ? 'pause armed · Qwen stops after this generate' : 'pause armed · finishing this generate')
    : data.trainingPaused
      ? (data.trainingStopQwen ? 'paused · Qwen stops when idle' : 'paused and saved')
      : data.status === 'autoplay_off'
        ? 'autoplay off · waiting'
        : data.status;
  $('updated').textContent = data.updatedAt ? new Date(data.updatedAt).toLocaleTimeString() : '';
  $('liveDot').style.background = !data.trainingPaused && live ? 'var(--green)' : 'var(--amber)';
  $('trainingToggle').textContent = armed
    ? 'PAUSE ARMED — WAIT'
    : data.trainingPaused ? 'RESUME SAVED TRAINING' : 'PAUSE & SAVE TRAINING';
  $('trainingToggle').dataset.paused=String(Boolean(data.trainingPaused));
  $('trainingToggle').dataset.armed=String(armed);
  const stopBtn=$('trainingStopQwen');
  stopBtn.hidden=Boolean(data.trainingPaused && data.trainingStopQwen);
  stopBtn.textContent=data.trainingPaused?'STOP QWEN (WHEN IDLE)':'PAUSE, SAVE & STOP QWEN';
  const autoplayOn=data.trainingAutoplay!==false;
  $('autoplayToggle').textContent=autoplayOn?'AUTOPLAY ON':'AUTOPLAY OFF';
  $('autoplayToggle').classList.toggle('is-off',!autoplayOn);
  $('autoplayToggle').dataset.on=String(autoplayOn);
  const lifetime = data.lifetime || {};
  const session = data.session || {};
  $('metrics').innerHTML = [
    ['Session tries',session.attempts],['Session passed',session.passed],['Session failed',session.failed],
    ['Session pass rate',pct(session.attempts ? session.passed/session.attempts : 0)],
    ['Reusable lessons',data.lessons?.length || 0],['Session infrastructure errors',session.infrastructureErrors],
  ].map(([label,value])=>`<div class="metric"><span>${label}</span><strong>${value ?? 0}</strong></div>`).join('');
  $('phase').textContent = data.status;
  $('active').innerHTML = data.active ? [
    ['Task',data.active.taskId],['Attempt',data.active.attempt],['Mode',data.active.objectiveMode || 'curriculum'],
  ].map(([a,b])=>`<div class="pill"><small class="meta">${a}</small><strong>${esc(b)}</strong></div>`).join('') : '<p class="meta">Between exercises.</p>';
  $('feedback').textContent = formatFeedback(data.active?.feedback) || 'No active failure.';
  $('advice').textContent = data.active?.advice || 'No tutor pass active.';
  $('tasks').innerHTML = bars((data.tasks||[]).map(t=>({
    label:`${t.title||humanize(t.id)} · ${t.mastery||'learning'}`,
    value:t.passRate,
    display:`${t.recentPassed||0}/${t.recentAttempts||0} recent · ${pct(t.passRate)}`,
  })));
  $('failures').innerHTML = bars((data.failures||[]).map(f=>({label:humanize(f.name),value:f.count})),true);
  const n=data.novelty||{};
  $('novelty').innerHTML=bars([
    {label:'New candidate source',value:n.newSource||0},{label:'Reused qualified source',value:n.knownLessonSource||0},{label:'Invalid / no source',value:n.noSource||0}
  ]);
  $('objectives').innerHTML=(data.objectives||[]).filter(o=>o.status!=='completed').slice().reverse().slice(0,8).map(o=>`<div class="queue"><strong>${esc(o.title)}</strong><div class="meta">${esc(o.mode)} · ${esc(o.status)} · ${(o.runIds||[]).length} runs</div></div>`).join('')||'<p class="meta">Queue empty. Completed work is retained in campaigns and the gallery.</p>';
  const university=data.university||{};
  const parked=new Set(data.scheduler?.parkedTaskIds||[]);
  const liveTask=data.active?.taskId||data.task||'';
  const studying=university.active&&!parked.has(university.active.id)?university.active:null;
  $('universityStatus').textContent=studying?`Studying ${studying.title}`:(parked.size?`Parked ${[...parked][0]} · live ${liveTask||'—'}`:'Preparing the next course');
  $('universityMetrics').innerHTML=[
    ['Degree courses',university.blueprintCount||0],
    ['Generated',university.generatedCount||0],
    ['Mastered',university.masteredCount||0],
  ].map(([a,b])=>`<div class="pill"><small class="meta">${a}</small><strong>${b}</strong></div>`).join('');
  $('universityCourses').innerHTML=(university.courses||[]).map(course=>{
    const isParked=parked.has(course.id);
    const isLive=liveTask===course.id;
    const stamp=isParked?'parked':isLive?'live':course.status;
    const tries=course.recentAttempts||0;
    const score=`${tries} tries · ${course.recentPassed||0} pass · ${course.recentFailed||0} fail · ${pct(course.recentPassRate)}`;
    return `<div class="queue"><strong>${esc(course.title)}</strong><div class="meta">Level ${course.level} · ${esc(course.discipline)} · ${esc(stamp)} · ${score}</div></div>`;
  }).join('')||'<p class="meta">The first course will be generated at the next scheduler selection.</p>';
  const objectiveById=new Map((data.objectives||[]).map(objective=>[objective.id,objective]));
  const campaignCard=c=>{
    const caps=c.capabilities||[];
    const alternatives=c.alternatives||[];
    const done=caps.filter(x=>x.outcome==='passed').length;
    const limited=caps.filter(x=>x.outcome==='attempt_limit').length;
    const running=caps.filter(x=>objectiveById.get(x.objectiveId)?.status==='running').length;
    const queued=caps.filter(x=>!x.outcome&&objectiveById.get(x.objectiveId)?.status!=='running').length;
    const showingAlternatives=alternatives.length>0;
    const ready=alternatives.filter(x=>x.status==='ready').length;
    const blocked=alternatives.filter(x=>x.status==='blocked').length;
    const segments=(showingAlternatives?alternatives:caps).map(x=>`<i class="${['ready','passed'].includes(x.status||x.outcome)?'done':['blocked','attempt_limit'].includes(x.status||x.outcome)?'limit':''}" title="${esc(x.title)}"></i>`).join('');
    const complete=['delivered','alternatives_ready'].includes(c.status);
    const setupDetails=caps.map(x=>{
      const attempts=(objectiveById.get(x.objectiveId)?.runIds||[]).length;
      const outcome=x.outcome==='attempt_limit'?`capped after ${attempts} fresh attempts`:x.outcome||'queued';
      return `${esc(x.title)}: ${esc(outcome)}`;
    }).join(' · ');
    const summary=showingAlternatives
      ? `${esc(c.brief.siteType)} · ${ready}/${alternatives.length} alternatives ready${blocked?` · ${blocked} blocked`:''}${c.status==='alternatives_ready'?' · generation complete':''}`
      : `${esc(c.brief.siteType)} · ${done}/${caps.length} setup checks passed${limited?` · ${limited} capped`:''}${running?` · ${running} running`:''}${queued?` · ${queued} queued`:''}${c.assemblyStage?` · ${esc(c.assemblyStage)} stage`:''}`;
    return `<article class="campaign"><div class="card-head"><strong>${esc(c.brief.name)}</strong><b class="${complete?'pass':''}">${esc(c.status).toUpperCase()}</b></div>
      <div class="meta">${summary}</div>
      <div class="campaign-progress">${segments}${showingAlternatives?'':`<i class="${c.status==='delivered'?'done':c.status==='delivered_limited'?'limit':''}" title="Staged site assembly"></i>`}</div>
      <p>${esc(c.brief.brief).slice(0,240)}</p>
      <div class="meta">${showingAlternatives?'Earlier setup probes: ':''}${setupDetails}${showingAlternatives?' · Final alternatives were independently browser-qualified.':''}</div>
      ${c.status==='blocked'&&!c.alternatives?`<button data-alternative-campaign="${esc(c.id)}">BUILD FOUR ALTERNATIVES</button>`:''}
      ${['alternatives_ready','alternatives_limited'].includes(c.status)?`<button data-alternative-campaign="${esc(c.id)}">RERUN FOUR ALTERNATIVES</button>`:''}</article>`;
  };
  const campaigns=(data.campaigns||[]).slice().reverse();
  const terminalStatuses=['blocked','superseded','delivered','delivered_limited','alternatives_ready','alternatives_limited'];
  const archived=campaigns.filter(c=>terminalStatuses.includes(c.status));
  const visible=campaigns.filter(c=>!terminalStatuses.includes(c.status));
  $('campaigns').innerHTML=visible.map(campaignCard).join('')||'<p class="meta">No active client campaigns.</p>';
  $('campaignHistory').innerHTML=archived.map(campaignCard).join('');
  $('campaignHistoryWrap').hidden=archived.length===0;
  $('campaignHistorySummary').textContent=`Completed / archived campaigns (${archived.length})`;
  const alternatives=campaigns.flatMap(campaign=>(campaign.alternatives||[]).map(variant=>({...variant,campaignName:campaign.brief.name})));
  $('alternatives').innerHTML=alternatives.map(variant=>`<article class="alternative">
    <div class="card-head"><strong>${esc(variant.title)}</strong><b class="${variant.status==='ready'?'pass':variant.status==='blocked'?'fail':''}">${esc(variant.status).toUpperCase()}</b></div>
    <p>${esc(variant.direction)}</p><div class="meta">${esc(variant.campaignName)}${variant.lastError?` · ${esc(variant.lastError)}`:''}</div>
    ${variant.runId?`<div class="preview-actions"><button data-preview="/preview/${esc(variant.runId)}" data-title="${esc(variant.title)}">OPEN QUALIFIED ALTERNATIVE</button><a class="preview-tab" href="/preview/${esc(variant.runId)}" target="_blank" rel="noopener">OPEN IN NEW TAB</a></div>`:''}
  </article>`).join('')||'<p class="meta">No alternative set has been requested.</p>';
  $('gallery').innerHTML=(data.gallery||[]).map(item=>`<article class="card">
    <div class="shots">${item.desktop?`<img src="${item.desktop}" alt="Desktop evidence">`:'<span></span>'}${item.mobile?`<img src="${item.mobile}" alt="Mobile evidence">`:''}</div>
    <div class="card-body"><div class="card-head"><strong>${esc(item.displayTitle||humanize(item.taskId))}</strong><b class="pass">QUALIFIED</b></div>
    <div class="meta">${esc(sourceLabel(item.novelty||'legacy receipt'))} · ${elapsed(item.durationMs)} · ${new Date(item.at).toLocaleString()}</div>
    ${item.preview?`<div class="preview-actions"><button data-preview="${item.preview}" data-title="${esc(item.displayTitle||humanize(item.taskId))}">OPEN ISOLATED PREVIEW</button><a class="preview-tab" href="${item.preview}" target="_blank" rel="noopener">OPEN IN NEW TAB</a></div>`:''}</div></article>`).join('')||'<p class="meta">No qualified showcase creations yet.</p>';
  $('events').innerHTML=(data.recentEvents||[]).map(e=>`<div class="event"><time>${new Date(e.at).toLocaleTimeString()}</time><strong>${esc(e.type)}</strong><small>${esc(e.taskId||e.message||e.runId||'')}</small></div>`).join('');
  if (!contractsLoaded) {
    $('contract').innerHTML=(data.contracts||[]).map(c=>`<option value="${esc(c.id)}">${esc(c.title)}</option>`).join('');
    contractsLoaded=true;
  }
}

async function refresh() {
  try {
    const response=await fetch('/api/snapshot',{cache:'no-store'});
    render(await response.json());
  } catch(error) {
    $('status').textContent='Dashboard error';
    $('updated').textContent=error.message;
  }
}

$('mode').addEventListener('change',()=>{$('contractWrap').style.display=$('mode').value==='qualify'?'grid':'none'});
$('mode').dispatchEvent(new Event('change'));
async function postTraining(payload){
  const response=await fetch('/api/training',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(payload)});
  const body=await response.json();
  if(!response.ok)throw new Error(body.error||'Training control failed.');
  await refresh();
}
$('trainingToggle').addEventListener('click',async()=>{
  const button=$('trainingToggle');
  if(button.disabled)return;
  if(button.dataset.armed==='true'){
    $('updated').textContent='Pause is armed. Wait until this generate finishes.';
    return;
  }
  button.disabled=true;
  const paused=button.dataset.paused!=='true';
  try{
    await postTraining({paused,stopQwen:false});
  }catch(error){
    $('updated').textContent=`Control failed: ${error.message}`;
  }finally{
    button.disabled=false;
  }
});
$('autoplayToggle').addEventListener('click',async()=>{
  const button=$('autoplayToggle');
  if(button.disabled)return;
  button.disabled=true;
  try{
    await postTraining({autoplay:button.dataset.on!=='true'});
  }catch(error){
    $('updated').textContent=`Control failed: ${error.message}`;
  }finally{
    button.disabled=false;
  }
});
$('trainingStopQwen').addEventListener('click',async()=>{
  const button=$('trainingStopQwen');
  if(button.disabled)return;
  button.disabled=true;
  try{
    await postTraining({paused:true,stopQwen:true});
  }catch(error){
    $('updated').textContent=`Control failed: ${error.message}`;
  }finally{
    button.disabled=false;
  }
});
$('coachForm').addEventListener('submit',event=>event.preventDefault());
$('coachForm').addEventListener('keydown',event=>{
  if(event.key==='Enter') event.preventDefault();
});
$('startCampaign').addEventListener('pointerup',async event=>{
  if(!event.isPrimary||event.button!==0) return;
  event.preventDefault();
  const button=$('startCampaign');
  if(button.disabled) return;
  button.disabled=true;
  $('coachResult').textContent='Planning campaign...';
  try{
    const response=await fetch('/api/campaigns',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({
      name:$('clientName').value,siteType:$('siteType').value,brief:$('clientBrief').value,
      pages:$('pages').value,brandNotes:$('brandNotes').value,styleReference:$('coachStyleReference').value,
      features:[...document.querySelectorAll('#featureChecks input:checked')].map(input=>input.value),
    })});
    const body=await response.json();
    $('coachResult').textContent=response.ok?`Campaign ${body.id} planned with ${body.capabilities.length} trusted training jobs.`:`Failed: ${body.error}`;
    if(response.ok){
      for(const id of ['clientName','clientBrief','pages','brandNotes','coachStyleReference']) $(id).value='';
      document.querySelectorAll('#featureChecks input:checked').forEach(input=>{input.checked=false});
    }
    refresh();
  }catch(error){
    $('coachResult').textContent=`Failed: ${error.message}`;
  }finally{
    button.disabled=false;
  }
});
$('objectiveForm').addEventListener('submit',async event=>{
  event.preventDefault();
  $('formResult').textContent='Queueing...';
  const response=await fetch('/api/objectives',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({
    mode:$('mode').value,title:$('title').value,prompt:$('prompt').value,
    styleReference:$('styleReference').value,contractTaskId:$('contract').value,
  })});
  const body=await response.json();
  $('formResult').textContent=response.ok?`Queued ${body.id}.`:`Failed: ${body.error}`;
  if(response.ok){$('title').value='';$('prompt').value='';}
  refresh();
});
document.addEventListener('click',event=>{
  const alternativesButton=event.target.closest('[data-alternative-campaign]');
  if(alternativesButton){
    alternativesButton.disabled=true;
    fetch(`/api/campaigns/${alternativesButton.dataset.alternativeCampaign}/alternatives`,{
      method:'POST',headers:{'Content-Type':'application/json'},body:'{}',
    }).then(async response=>{
      const body=await response.json();
      if(!response.ok)throw new Error(body.error||'Alternative request failed.');
      await refresh();
    }).catch(error=>{$('updated').textContent=`Alternative request failed: ${error.message}`})
      .finally(()=>{alternativesButton.disabled=false});
    return;
  }
  const button=event.target.closest('[data-preview]');
  if(!button)return;
  $('previewTitle').textContent=button.dataset.title;
  $('previewFrame').src=button.dataset.preview;
  $('openPreviewTab').href=button.dataset.preview;
  $('previewDialog').showModal();
});
$('closePreview').addEventListener('click',()=>{$('previewFrame').src='about:blank';$('previewDialog').close()});
refresh();
setInterval(refresh,2000);
