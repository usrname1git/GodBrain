const $ = id => document.getElementById(id);
const esc = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const pct = value => `${Math.round((value || 0) * 100)}%`;
const elapsed = ms => ms == null ? '-' : ms < 1000 ? `${ms}ms` : `${(ms / 1000).toFixed(1)}s`;
const humanize = value => String(value ?? '').replace(/-v\d+$/,'').replaceAll('-',' ').replace(/^./,c=>c.toUpperCase());
const sourceLabel = value => ({new_source:'New candidate source',known_lesson_source:'Reused qualified source',no_source:'Invalid / no source'}[value]||humanize(value));
const previewActions = (preview,title,label='OPEN SAVED WEBSITE') => preview?.url
  ? `<div class="preview-actions"><button data-preview="${esc(preview.url)}" data-title="${esc(title)}">${esc(label)}</button><a class="preview-tab" href="${esc(preview.url)}" target="_blank" rel="noopener">OPEN IN NEW TAB</a></div>`
  : preview?.error ? `<p class="fail">${esc(preview.error)}</p>` : '';
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

function examinerStale(course) {
  return (course.recentAttempts || 0) >= 8 && (course.recentPassRate || 0) < 1;
}

function render(data) {
  const university=data.university||{};
  const staleCourses=(university.courses||[]).filter(examinerStale);
  const live=['generating','evaluating','learning','consulting_tutor'].includes(data.status);
  const armed=Boolean(data.trainingPaused && live);
  $('status').textContent = armed
    ? (data.trainingStopQwen ? 'pause armed · Qwen stops after this generate' : 'pause armed · finishing this generate')
    : data.trainingPaused
      ? (data.trainingStopQwen ? 'paused · Qwen stops when idle' : 'paused and saved')
      : data.status === 'autoplay_off'
        ? 'course autoplay off · waiting for manual work'
        : data.status === 'ladder_complete'
          ? (staleCourses.length
              ? `idle · ${staleCourses.length} courses under 100%`
              : 'ladder complete · all sampled courses 100%')
          : data.status;
  $('updated').textContent = data.updatedAt ? new Date(data.updatedAt).toLocaleTimeString() : '';
  $('liveDot').style.background = !data.trainingPaused && live ? 'var(--green)' : 'var(--amber)';
  $('trainingToggle').textContent = armed
    ? 'PAUSE ARMED — WAIT'
    : data.trainingPaused ? 'RESUME SAVED WORK' : 'PAUSE & SAVE WORK';
  $('trainingToggle').dataset.paused=String(Boolean(data.trainingPaused));
  $('trainingToggle').dataset.armed=String(armed);
  const stopBtn=$('trainingStopQwen');
  stopBtn.hidden=Boolean(data.trainingPaused && data.trainingStopQwen);
  stopBtn.textContent=data.trainingPaused?'STOP QWEN (WHEN IDLE)':'PAUSE, SAVE & STOP QWEN';
  const autoplayOn=data.trainingAutoplay!==false;
  $('autoplayToggle').textContent=autoplayOn?'COURSE AUTOPLAY ON':'COURSE AUTOPLAY OFF';
  $('autoplayToggle').classList.toggle('is-off',!autoplayOn);
  $('autoplayToggle').dataset.on=String(autoplayOn);
  const lifetime = data.lifetime || {};
  const session = data.session || {};
  $('metrics').innerHTML = [
    ['Session tries',session.attempts],['Session passed',session.passed],['Session failed',session.failed],
    ['Session pass rate',pct(session.attempts ? session.passed/session.attempts : 0)],
    ['Compatible lessons',data.lessons?.length || 0],['Session infrastructure errors',session.infrastructureErrors],
  ].map(([label,value])=>`<div class="metric"><span>${label}</span><strong>${value ?? 0}</strong></div>`).join('');
  const db=data.builderDatabase;
  $('builderDatabaseStatus').textContent=db
    ? db.ok===1?`${db.database}: insert/read/update/read passed at ${new Date(db.at).toLocaleString()}. Database round-trip only; not a verdict on this website's features.`
      : `Backend check failed: ${db.error}`
    : 'Backend tests use godbrain_builder_test with synthetic records; they do not prove website feature integration.';
  const shared=data.sharedLessons;
  $('sharedLessonsStatus').textContent=shared
    ? shared.ok===1?`${shared.database}: ${shared.stored} stored lessons · ${shared.compatible} compatible with this verifier · shared across models.`
      : `Shared memory pending: ${shared.error}. Local evidence is retained.`
    : `${data.storedLessonCount||0} local lesson records; shared-memory sync has not completed.`;
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
  const parked=new Set(data.scheduler?.parkedTaskIds||[]);
  const liveTask=data.active?.taskId||data.task||'';
  const studying=university.active&&!parked.has(university.active.id)?university.active:null;
  const graduated=university.programStatus==='graduated';
  $('universityStatus').textContent=graduated
    ?(staleCourses.length
        ?`Ledger ${university.masteredCount||0}/${university.blueprintCount||0} · ${staleCourses.length} under 100%`
        :`Ladder complete · ${university.programTitle||'Frontend mastery'}`)
    :(studying?`Cycle ${studying.cycle} · Stage ${studying.stage} · ${studying.title}`:(parked.size?`Parked ${[...parked][0]} · live ${liveTask||'—'}`:'Preparing the next course'));
  $('universityMetrics').innerHTML=[
    ['Program',graduated?(staleCourses.length?'Crowned · not 100%':'Complete'):(university.currentCycle?`C${university.currentCycle} S${university.currentStage}`:'Enrolled')],
    ['Courses',`${university.masteredCount||0}/${university.blueprintCount||0}`],
    ['Cycle',studying?.cycle||university.currentCycle||'—'],
  ].map(([a,b])=>`<div class="pill"><small class="meta">${a}</small><strong>${b}</strong></div>`).join('');
  $('universityCourses').innerHTML=(university.courses||[]).map(course=>{
    const isParked=parked.has(course.id);
    const isLive=liveTask===course.id;
    const stamp=isParked?'parked':isLive?'live':examinerStale(course)?'stale vs examiner':course.status;
    const tries=course.recentAttempts||0;
    const score=`${tries} tries · ${course.recentPassed||0} pass · ${course.recentFailed||0} fail · ${pct(course.recentPassRate)}`;
    const when=course.cycle&&course.stage?`C${course.cycle} S${course.stage}`:`Level ${course.level}`;
    return `<div class="queue"><strong>${esc(course.title)}</strong><div class="meta">${when} · ${esc(course.discipline)} · ${esc(stamp)} · ${score}</div></div>`;
  }).join('')||'<p class="meta">The first course will be generated at the next scheduler selection.</p>';
  const objectiveById=new Map((data.objectives||[]).map(objective=>[objective.id,objective]));
  const campaignCard=c=>{
    const caps=c.capabilities||[];
    const alternatives=c.alternatives||[];
    const showingAlternatives=alternatives.length>0;
    const ready=alternatives.filter(x=>x.status==='ready').length;
    const blocked=alternatives.filter(x=>x.status==='blocked').length;
    const assembly=objectiveById.get(c.assemblyObjectiveId);
    const terminal=['delivered','delivered_limited','blocked','alternatives_ready','alternatives_limited'].includes(c.status);
    const status=c.status==='showcasing'?`GENERATING SET ${c.alternativeGeneration||1}`
      :c.status==='assembling'?(assembly?.status==='queued'?'QUEUED':data.active?.taskId===`objective-${assembly?.id}`&&data.status==='evaluating'?'CHECKING':'GENERATING')
      :['delivered','alternatives_ready'].includes(c.status)?'READY':c.status.toUpperCase();
    const segments=(showingAlternatives?alternatives:caps).map(x=>`<i class="${['ready','passed'].includes(x.status||x.outcome)?'done':['blocked','attempt_limit'].includes(x.status||x.outcome)?'limit':''}" title="${esc(x.title)}"></i>`).join('');
    const complete=['delivered','alternatives_ready'].includes(c.status);
    const setupDetails=caps.map(x=>{
      const attempts=(objectiveById.get(x.objectiveId)?.runIds||[]).length;
      const outcome=x.outcome==='attempt_limit'?`capped after ${attempts} fresh attempts`:x.outcome||'queued';
      return `${esc(x.title)}: ${esc(outcome)}`;
    }).join(' · ');
    const summary=showingAlternatives
      ? `${esc(c.brief.siteType)} · set ${c.alternativeGeneration||1} · ${ready}/${alternatives.length} alternatives ready${blocked?` · ${blocked} blocked`:''}${c.status==='alternatives_ready'?' · generation complete':''}`
      : `${esc(c.brief.siteType)} · website version ${c.buildGeneration||1} · ${esc(c.assemblyStage||c.status)}${assembly?.status==='queued'?' queued':''}`;
    const history=(c.alternativeHistory||[]).filter(set=>set.generation!==c.alternativeGeneration||!showingAlternatives);
    return `<article class="campaign"><div class="card-head"><strong>${esc(c.brief.name)}</strong><b class="${complete?'pass':''}">${esc(status)}</b></div>
      <div class="meta">${summary}</div>
      <div class="campaign-progress">${showingAlternatives?segments:`<i class="done" title="Explicit generation requested"></i><i class="${c.buildPreview?.url?'done':''}" title="Browser-checked shell"></i><i class="${c.status==='delivered'?'done':c.status==='delivered_limited'||c.status==='blocked'?'limit':''}" title="Final integration"></i>`}</div>
      <p>${esc(c.brief.brief).slice(0,240)}</p>
      ${caps.length?`<div class="meta">Earlier setup probes: ${setupDetails}</div>`:''}
      ${c.lastError?`<p class="meta">${esc(c.lastError)}</p>`:''}
      ${previewActions(c.buildPreview,c.brief.name,c.status==='assembling'?'OPEN PASSING SHELL':'OPEN SAVED WEBSITE')}
      ${alternatives.map(v=>previewActions(v.preview,v.title,v.title)).join('')}
      ${(c.buildHistory||[]).length?`<details data-campaign-history="${esc(c.id)}:build"><summary>Previous website versions (${c.buildHistory.length})</summary>${c.buildHistory.slice().reverse().map(build=>`<p class="meta">Version ${build.generation||'original'} · ${esc(build.status)}</p>${previewActions(build.preview,c.brief.name)}`).join('')}</details>`:''}
      ${history.length?`<details data-campaign-history="${esc(c.id)}:alternatives"><summary>Previous alternative sets (${history.length})</summary>${history.slice().reverse().map(set=>`<p class="meta">Set ${set.generation} · ${esc(set.status)}</p><div class="campaign-progress">${set.alternatives.map(v=>`<i class="${v.status==='ready'?'done':v.status==='blocked'?'limit':''}" title="${esc(v.title)}"></i>`).join('')}</div>${set.alternatives.map(v=>previewActions(v.preview,v.title,v.title)).join('')}`).join('')}</details>`:''}
      ${terminal?`<button data-regenerate-campaign="${esc(c.id)}">REGENERATE</button>`:''}</article>`;
  };
  const campaigns=(data.campaigns||[]).slice().reverse();
  const projectKey=c=>`${c.brief.name.trim().toLowerCase()}:${c.brief.siteType}`;
  const latest=new Map();
  for(const c of campaigns)if(c.status!=='superseded'&&!latest.has(projectKey(c)))latest.set(projectKey(c),c.id);
  const visible=campaigns.filter(c=>latest.get(projectKey(c))===c.id);
  const archived=campaigns.filter(c=>latest.get(projectKey(c))!==c.id);
  const openHistories=new Set([...document.querySelectorAll('details[data-campaign-history][open]')].map(node=>node.dataset.campaignHistory));
  $('campaigns').innerHTML=visible.map(campaignCard).join('')||'<p class="meta">No active client campaigns.</p>';
  $('campaignHistory').innerHTML=archived.map(campaignCard).join('');
  for(const node of document.querySelectorAll('details[data-campaign-history]'))node.open=openHistories.has(node.dataset.campaignHistory);
  $('campaignHistoryWrap').hidden=archived.length===0;
  $('campaignHistorySummary').textContent=`Completed / archived campaigns (${archived.length})`;
  const alternatives=campaigns.flatMap(campaign=>{
    const sets=[{generation:campaign.alternativeGeneration,alternatives:campaign.alternatives||[]}];
    if(!sets[0].alternatives.length||sets[0].alternatives.some(v=>v.status!=='ready')){
      const saved=(campaign.alternativeHistory||[]).filter(set=>set.status==='alternatives_ready').at(-1);
      if(saved&&saved.generation!==sets[0].generation)sets.push(saved);
    }
    return sets.flatMap(set=>set.alternatives.map(variant=>({...variant,campaignName:`${campaign.brief.name} · set ${set.generation}`})));
  });
  $('alternatives').innerHTML=alternatives.map(variant=>`<article class="alternative">
    <div class="card-head"><strong>${esc(variant.title)}</strong><b class="${variant.status==='ready'?'pass':variant.status==='blocked'?'fail':''}">${esc(variant.status).toUpperCase()}</b></div>
    <p>${esc(variant.direction)}</p><div class="meta">${esc(variant.campaignName)}${variant.lastError?` · ${esc(variant.lastError)}`:''}</div>
    ${previewActions(variant.preview,variant.title,'OPEN QUALIFIED ALTERNATIVE')}
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
    const body=await response.json();
    if(!response.ok)throw new Error(body.error||response.statusText);
    render(body);
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
    $('coachResult').textContent=response.ok?`Website ${body.id} queued. This generation runs once; regeneration is manual.`:`Failed: ${body.error}`;
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
  const regenerateButton=event.target.closest('[data-regenerate-campaign]');
  if(regenerateButton){
    regenerateButton.disabled=true;
    fetch(`/api/campaigns/${regenerateButton.dataset.regenerateCampaign}/regenerate`,{
      method:'POST',headers:{'Content-Type':'application/json'},body:'{}',
    }).then(async response=>{
      const body=await response.json();
      if(!response.ok)throw new Error(body.error||'Regeneration failed.');
      await refresh();
    }).catch(error=>{$('updated').textContent=`Regeneration failed: ${error.message}`})
      .finally(()=>{regenerateButton.disabled=false});
    return;
  }
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
for(const [id,url] of [['testBuilderDatabase','/api/builder/database-check'],['syncSharedLessons','/api/builder/shared-lessons']]){
  $(id).addEventListener('click',async()=>{
    const button=$(id);
    button.disabled=true;
    try{
      const response=await fetch(url,{method:'POST',headers:{'Content-Type':'application/json'},body:'{}'});
      const body=await response.json();
      if(!response.ok)throw new Error(body.error||'Builder check failed.');
      await refresh();
    }catch(error){$('updated').textContent=`Builder check failed: ${error.message}`}
    finally{button.disabled=false}
  });
}
refresh();
setInterval(refresh,2000);
