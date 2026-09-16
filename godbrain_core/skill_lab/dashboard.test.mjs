import assert from 'node:assert/strict';
import { promises as fs } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { startDashboard } from './dashboard.mjs';
import {
  advanceCampaigns, createCampaign, listCampaigns, requestCampaignAlternatives, validateClientBrief,
} from './coach.mjs';
import {
  claimObjective, completeObjective, enqueueObjective, listObjectives, validateObjective,
} from './objectives.mjs';
import { writeJson } from './gym-core.mjs';

const labRoot = path.dirname(fileURLToPath(import.meta.url));
const trustedTasks = [{
  id: 'trusted-v1', family: 'trusted', title: 'Trusted contract',
  docs: [], brief: 'A browser-qualified trusted functional contract.', qualityProfile: 'showcase',
}, {
  id: 'keyboard-tabs-dialog-v1', family: 'a11y', title: 'Keyboard navigation',
  docs: [], brief: 'Keyboard contract.',
}];

async function workspace(t) {
  const root = path.join(labRoot, 'work', 'tests');
  await fs.mkdir(root, { recursive: true });
  const dir = await fs.mkdtemp(path.join(root, 'dashboard-'));
  t.after(() => fs.rm(dir, { recursive: true, force: true }));
  return dir;
}

test('objective validation keeps free exploration separate from trusted qualification', async t => {
  const workDir = await workspace(t);
  assert.deepEqual(validateObjective({
    mode: 'explore', title: 'Graph lab', prompt: 'Build a graph workspace.',
    styleReference: 'https://github.com/hi77x/appgraph',
  }, trustedTasks), {
    mode: 'explore', title: 'Graph lab', prompt: 'Build a graph workspace.',
    styleReference: 'https://github.com/hi77x/appgraph', contractTaskId: '',
  });

  test('custom objective token budgets leave room in the local 8K context', async t => {
    const workDir = await workspace(t);
    await enqueueObjective(workDir, {
      mode: 'explore', title: 'Bounded generation', prompt: 'Build a compact frontend.',
    }, trustedTasks, { maxTokens: 5000 });
    const task = await claimObjective(workDir, trustedTasks);
    assert.equal(task.maxTokens, 4096);
  });

  test('staged objectives merge one generated file with trusted seed source', async t => {
    const workDir = await workspace(t);
    const app = await enqueueObjective(workDir, {
      mode: 'qualify', title: 'Structure', prompt: 'Build the structure.',
      contractTaskId: 'trusted-v1',
    }, trustedTasks, { fileMode: 'app', evaluationProfile: 'structure-draft' });
    const appTask = await claimObjective(workDir, trustedTasks);
    assert.equal(appTask.fileMode, 'app');
    assert.equal(appTask.retainLesson, false);
    assert.match(appTask.initialFiles['styles.css'], /box-sizing/);
    const runId = '00000003-cccccccccccc';
    await fs.mkdir(path.join(workDir, 'runs', runId), { recursive: true });
    await writeJson(path.join(workDir, 'runs', runId, 'source.json'), {
      'App.jsx': 'export default function App(){return <main>Seed</main>}',
      'styles.css': 'body{color:#123}',
    });
    await completeObjective(workDir, app.id, { runId }, 'passed');
    await enqueueObjective(workDir, {
      mode: 'qualify', title: 'Style', prompt: 'Style the structure.',
      contractTaskId: 'trusted-v1',
    }, trustedTasks, { fileMode: 'styles', initialRunId: runId });
    const stylesTask = await claimObjective(workDir, trustedTasks);
    assert.equal(stylesTask.fileMode, 'styles');
    assert.equal(stylesTask.initialFiles['App.jsx'].includes('Seed'), true);
  });
  assert.throws(() => validateObjective({
    mode: 'qualify', title: 'Fake', prompt: 'Pass my own test.', contractTaskId: 'invented',
  }, trustedTasks), /existing trusted verifier/);
  const queued = await enqueueObjective(workDir, {
    mode: 'qualify', title: 'Merchant UI', prompt: 'Use a Shopify-style visual system.',
    contractTaskId: 'trusted-v1',
  }, trustedTasks);
  const task = await claimObjective(workDir, trustedTasks);
  assert.equal(task.objectiveId, queued.id);
  assert.equal(task.baseTaskId, 'trusted-v1');
  assert.equal(task.retainLesson, true);
  assert.match(task.brief, /Trusted functional contract/);
  assert.equal((await listObjectives(workDir))[0].status, 'running');
  const reclaimed = await claimObjective(workDir, trustedTasks);
  assert.equal(reclaimed.objectiveId, queued.id);
});

test('concurrent objective submissions are serialized without losing requests', async t => {
  const workDir = await workspace(t);
  const submitted = await Promise.all(Array.from({ length: 12 }, (_, index) =>
    enqueueObjective(workDir, {
      mode: 'explore', title: `Objective ${index}`, prompt: `Build interface ${index}.`,
    }, trustedTasks)));
  const queued = await listObjectives(workDir);
  assert.equal(queued.length, submitted.length);
  assert.deepEqual(new Set(queued.map(item => item.id)), new Set(submitted.map(item => item.id)));
});

test('completed objective verdicts are immutable across replayed completion callbacks', async t => {
  const workDir = await workspace(t);
  const item = await enqueueObjective(workDir, {
    mode: 'explore', title: 'Immutable', prompt: 'Build once.',
  }, trustedTasks);
  await completeObjective(workDir, item.id, { runId: 'passing-run' }, 'passed');
  await completeObjective(workDir, item.id, { runId: 'replayed-failure' }, 'attempt_limit');
  const stored = (await listObjectives(workDir))[0];
  assert.equal(stored.outcome, 'passed');
  assert.deepEqual(stored.runIds, ['passing-run']);
});

test('coach converts a client brief into trusted practice and queues assembly after training', async t => {
  const workDir = await workspace(t);
  const contracts = [
    ...trustedTasks,
    { id: 'catalog-search-sort-v1', family: 'catalog', title: 'Catalog', docs: [], brief: 'Catalog contract.' },
    { id: 'registration-validation-v1', family: 'forms', title: 'Registration', docs: [], brief: 'Registration contract.' },
    { id: 'settings-persistence-v1', family: 'settings', title: 'Settings', docs: [], brief: 'Settings contract.' },
    { id: 'task-list-productivity-v1', family: 'workflow', title: 'Workflow', docs: [], brief: 'Workflow contract.' },
  ];
  assert.throws(() => validateClientBrief({ siteType: 'storefront', name: '', brief: 'x' }), /Project name/);
  const campaign = await createCampaign(workDir, {
    name: 'Northstar', siteType: 'storefront', brief: 'Build a premium audio store.',
    features: ['account-settings', 'workflow'], styleReference: 'https://example.test/design',
  }, contracts);
  assert.equal(campaign.status, 'training');
  assert.ok(campaign.capabilities.length >= 4);
  let objectives = await listObjectives(workDir);
  assert.equal(objectives.length, campaign.capabilities.length);
  for (const item of objectives) {
    await completeObjective(workDir, item.id, { runId: `run-${item.id}` }, 'passed');
  }
  let campaigns = await advanceCampaigns(workDir, contracts);
  assert.equal(campaigns[0].status, 'assembling');
  const objectiveCount = (await listObjectives(workDir)).length;
  await advanceCampaigns(workDir, contracts);
  assert.equal((await listObjectives(workDir)).length, objectiveCount);
  objectives = await listObjectives(workDir);
  const assembly = objectives.find(item => item.id === campaigns[0].assemblyObjectiveId);
  assert.equal(assembly.mode, 'explore');
  assert.match(assembly.prompt, /compact but complete first-pass/i);
  const shellRunId = '00000001-aaaaaaaaaaaa';
  await fs.mkdir(path.join(workDir, 'runs', shellRunId), { recursive: true });
  await writeJson(path.join(workDir, 'runs', shellRunId, 'source.json'), {
    'App.jsx': 'export default function App(){return <main>Northstar</main>}',
    'styles.css': 'body{margin:0}',
  });
  await completeObjective(workDir, assembly.id, { runId: shellRunId }, 'passed');
  campaigns = await advanceCampaigns(workDir, contracts);
  assert.equal(campaigns[0].status, 'assembling');
  assert.equal(campaigns[0].assemblyStage, 'polish');
  objectives = await listObjectives(workDir);
  const polish = objectives.find(item => item.id === campaigns[0].assemblyObjectiveId);
  assert.equal(polish.initialRunId, shellRunId);
  const claimedPolish = await claimObjective(workDir, contracts);
  assert.deepEqual(claimedPolish.initialFiles, {
    'App.jsx': 'export default function App(){return <main>Northstar</main>}',
    'styles.css': 'body{margin:0}',
  });
  await completeObjective(workDir, polish.id, { runId: '00000002-bbbbbbbbbbbb' }, 'passed');
  campaigns = await advanceCampaigns(workDir, contracts);
  assert.equal(campaigns[0].status, 'delivered');
  assert.ok(campaigns[0].deliveredAt);
});

test('assembly attempt exhaustion replans once before blocking', async t => {
  const workDir = await workspace(t);
  const campaign = await createCampaign(workDir, {
    name: 'Blocked build', siteType: 'custom', brief: 'Build a custom site.', features: [],
  }, trustedTasks);
  for (const capability of campaign.capabilities) {
    await completeObjective(workDir, capability.objectiveId, { runId: 'capability-run' }, 'passed');
  }
  let campaigns = await advanceCampaigns(workDir, trustedTasks);
  const assemblyId = campaigns[0].assemblyObjectiveId;
  await completeObjective(workDir, assemblyId, { runId: 'failed-assembly' }, 'attempt_limit');
  campaigns = await advanceCampaigns(workDir, trustedTasks);
  assert.equal(campaigns[0].status, 'assembling');
  assert.equal(campaigns[0].assemblyStage, 'shell-recovery');
  const recoveryId = campaigns[0].assemblyObjectiveId;
  assert.notEqual(recoveryId, assemblyId);
  await completeObjective(workDir, recoveryId, { runId: 'failed-recovery' }, 'attempt_limit');
  campaigns = await advanceCampaigns(workDir, trustedTasks);
  assert.equal(campaigns[0].status, 'blocked');
  assert.equal(campaigns[0].deliveredAt, null);
  assert.match(campaigns[0].lastError, /recovery limit/);
});

test('blocked client work can become four staged distinct alternatives', async t => {
  const workDir = await workspace(t);
  const contracts = [
    ...trustedTasks,
    { id: 'event-platform-showcase-v1', family: 'marketing-sites', title: 'Showcase',
      qualityProfile: 'marketing-site-v1', docs: [], brief: 'Complete event-platform showcase contract.' },
  ];
  await writeJson(path.join(workDir, 'campaigns.json'), {
    version: 1,
    items: [{
      id: 'trippus12345', createdAt: new Date().toISOString(), updatedAt: new Date().toISOString(),
      status: 'blocked',
      brief: {
        name: 'Trippus Next', siteType: 'business', brief: 'Build a stronger event platform site.',
        pages: 'Home; Platform; Pricing; Demo', features: [], styleReference: 'https://www.trippus.com/',
        brandNotes: 'Premium Scandinavian B2B SaaS.',
      },
      capabilities: [], assemblyObjectiveId: null, assemblyRunIds: [], deliveredAt: null, lastError: 'Old failure',
      recoveryStartedAt: new Date().toISOString(),
    }],
  });
  const campaign = await requestCampaignAlternatives(workDir, 'trippus12345', contracts);
  assert.equal(campaign.status, 'showcasing');
  assert.equal(campaign.alternatives.length, 4);
  let objectives = await listObjectives(workDir);
  assert.equal(objectives.filter(item => item.campaignStage === 'alternative-styles').length, 4);
  const variant = campaign.alternatives[0];
  const stylesObjective = objectives.find(item => item.id === variant.styleObjectiveId);
  assert.equal(stylesObjective.fileMode, 'styles');
  assert.equal(stylesObjective.templateTaskId, 'event-platform-showcase-v1');
  const claimed = await claimObjective(workDir, contracts);
  assert.equal(claimed.fileMode, 'styles');
  assert.equal(claimed.maxTokens, 4096);
  assert.match(claimed.initialFiles['App.jsx'], /lifecycle/);
  const finalRunId = '00000005-eeeeeeeeeeee';
  await fs.mkdir(path.join(workDir, 'runs', finalRunId), { recursive: true });
  await writeJson(path.join(workDir, 'runs', finalRunId, 'receipt.json'), {
    sourceHash: 'source-final',
    evidence: [{ visualFingerprint: 'visual-final' }],
  });
  await completeObjective(workDir, stylesObjective.id, { runId: finalRunId }, 'passed');
  await advanceCampaigns(workDir, contracts);
  assert.equal((await listCampaigns(workDir))[0].alternatives[0].status, 'ready');
});

test('a completed alternative set can be rerun without overwriting its evidence', async t => {
  const workDir = await workspace(t);
  const contracts = [
    ...trustedTasks,
    { id: 'event-platform-showcase-v1', family: 'marketing-sites', title: 'Showcase',
      qualityProfile: 'marketing-site-v1', docs: [], brief: 'Complete event-platform showcase contract.' },
  ];
  const alternatives = [
    ['nordic-editorial', 'Nordic editorial'],
    ['product-led', 'Product-led interactive'],
    ['enterprise-trust', 'Enterprise trust'],
    ['event-experience', 'Event experience'],
  ].map(([id, title], index) => ({
    id, title, direction: `${title} direction.`, status: 'ready',
    styleRetry: 0, runId: `0000000${index + 1}-${String(index + 1).repeat(12)}`,
    sourceHash: `source-${index}`, visualFingerprint: `visual-${index}`,
    completedAt: new Date().toISOString(), lastError: null,
  }));
  await writeJson(path.join(workDir, 'campaigns.json'), {
    version: 1,
    items: [{
      id: 'rerun1234567', createdAt: new Date().toISOString(), updatedAt: new Date().toISOString(),
      status: 'alternatives_ready', alternativeGeneration: 1,
      brief: {
        name: 'Trippus Next', siteType: 'business', brief: 'Build stronger alternatives.',
        pages: '', features: [], styleReference: '', brandNotes: '',
      },
      capabilities: [], assemblyObjectiveId: null, assemblyRunIds: [], deliveredAt: null,
      lastError: null, alternatives,
    }],
  });

  const campaign = await requestCampaignAlternatives(workDir, 'rerun1234567', contracts);
  assert.equal(campaign.status, 'showcasing');
  assert.equal(campaign.alternativeGeneration, 2);
  assert.equal(campaign.alternativeHistory.length, 1);
  assert.equal(campaign.alternativeHistory[0].alternatives[0].runId, alternatives[0].runId);
  assert.equal(campaign.alternatives.every(item => item.status === 'qualifying'), true);
  const objectives = await listObjectives(workDir);
  assert.equal(objectives.length, 4);
  assert.equal(objectives.every(item => item.stableKey.includes(':set-v2:styles-v1')), true);
});

test('coach persists intermediate progress and rejects a duplicate active project', async t => {
  const workDir = await workspace(t);
  const campaign = await createCampaign(workDir, {
    name: 'Persistent client', siteType: 'custom', brief: 'Build the client site.', features: [],
  }, trustedTasks);
  await completeObjective(workDir, campaign.capabilities[0].objectiveId, { runId: 'capability-run' }, 'passed');
  const campaigns = await advanceCampaigns(workDir, trustedTasks);
  assert.equal(campaigns[0].capabilities[0].outcome, 'passed');
  assert.equal((await listCampaigns(workDir))[0].capabilities[0].outcome, 'passed');
  await assert.rejects(createCampaign(workDir, {
    name: ' persistent CLIENT ', siteType: 'custom', brief: 'A second submission.', features: [],
  }, trustedTasks), /active campaign named/i);
});

test('a planning campaign resumes missing objective creation after restart', async t => {
  const workDir = await workspace(t);
  await writeJson(path.join(workDir, 'campaigns.json'), {
    version: 1,
    items: [{
      id: 'recover123456', createdAt: new Date().toISOString(), updatedAt: new Date().toISOString(),
      status: 'planning',
      brief: {
        name: 'Recovered', siteType: 'custom', brief: 'Resume this campaign.',
        pages: '', features: [], styleReference: '', brandNotes: '',
      },
      capabilities: [{
        contractTaskId: 'keyboard-tabs-dialog-v1', title: 'Keyboard navigation',
        stableKey: 'campaign:recover123456:capability:keyboard-tabs-dialog-v1',
        objectiveId: null, outcome: null,
      }],
      assemblyObjectiveId: null, assemblyRunIds: [], deliveredAt: null, lastError: null,
    }],
  });
  const campaigns = await advanceCampaigns(workDir, trustedTasks);
  assert.equal(campaigns[0].status, 'training');
  assert.ok(campaigns[0].capabilities[0].objectiveId);
  assert.equal((await listObjectives(workDir)).length, 1);
});

test('maximum accepted client fields are bounded into valid objective prompts', async t => {
  const workDir = await workspace(t);
  const campaign = await createCampaign(workDir, {
    name: 'Large brief', siteType: 'custom',
    brief: 'b'.repeat(3000), pages: 'p'.repeat(1000),
    brandNotes: 'n'.repeat(1600), styleReference: 's'.repeat(1200), features: [],
  }, trustedTasks);
  assert.equal(campaign.status, 'training');
  const objectives = await listObjectives(workDir);
  assert.equal(objectives.length, 1);
  assert.ok(objectives[0].prompt.length <= 1200);
});

test('dashboard is loopback-only, reports state, accepts same-origin objectives and rejects traversal', async t => {
  const workDir = await workspace(t);
  const qualityRun = '00000001-aaaaaaaaaaaa';
  const legacyRun = '00000002-bbbbbbbbbbbb';
  await writeJson(path.join(workDir, 'state.json'), {
    version: 1, status: 'running', sequence: 0, cursor: 0, active: null,
    stats: { attempts: 4, passed: 3, failed: 1, infrastructureErrors: 2, byTask: {
      'trusted-v1': { attempted: 4, passed: 3, failed: 1 },
      'objective-internal123': { attempted: 4, passed: 0, failed: 4 },
    } },
    lessons: [], recent: [qualityRun, legacyRun], updatedAt: new Date().toISOString(),
    session: {
      id: 'session-test', startedAt: new Date().toISOString(),
      baseline: { attempts: 1, passed: 1, failed: 0, infrastructureErrors: 1 },
    },
  });
  await fs.writeFile(path.join(workDir, 'events.jsonl'), [
    JSON.stringify({ at: '2020-01-01T00:00:00.000Z', type: 'exercise_passed', novelty: 'known_lesson_source' }),
    JSON.stringify({ at: new Date().toISOString(), type: 'attempt_failed', failedChecks: ['keyboard'], novelty: 'new_source' }),
    '',
  ].join('\n'));
  for (const [runId, taskId] of [[qualityRun, 'trusted-v1'], [legacyRun, 'keyboard-tabs-dialog-v1']]) {
    await fs.mkdir(path.join(workDir, 'runs', runId), { recursive: true });
    await writeJson(path.join(workDir, 'runs', runId, 'receipt.json'), {
      runId, taskId, at: new Date().toISOString(), passed: true,
      sourceHash: runId.slice(-12).padEnd(64, '0'), evidence: [], timings: { totalMs: 1 },
    });
  }
  const dashboard = await startDashboard({ workDir, trustedTasks, port: 0 });
  t.after(() => dashboard.close());
  assert.match(dashboard.origin, /^http:\/\/127\.0\.0\.1:\d+$/);
  const page = await fetch(dashboard.origin);
  assert.equal(page.status, 200);
  const pageText = await page.text();
  assert.match(pageText, /Creation Gallery/);
  assert.match(pageText, /<textarea id="pages"/);
  assert.match(pageText, /id="coachStyleReference"/);
  assert.match(pageText, /id="startCampaign" type="button"/);
  assert.match(pageText, /id="trainingToggle"/);
  assert.match(pageText, /id="campaignHistory"/);
  assert.match(pageText, /Frontend University/);
  assert.ok(pageText.indexOf('id="metrics"') < pageText.indexOf('Frontend University'));
  assert.ok(pageText.indexOf('Frontend University') < pageText.indexOf('Live loop'));
  assert.ok(pageText.indexOf('Live loop') < pageText.indexOf('New training objective'));
  assert.ok(pageText.indexOf('New training objective') < pageText.indexOf('Frontend Coach'));
  const script = await (await fetch(`${dashboard.origin}/dashboard.js`)).text();
  assert.match(script, /startCampaign'\)\.addEventListener\('pointerup'/);
  assert.match(script, /if\(event\.key==='Enter'\) event\.preventDefault\(\)/);
  assert.match(script, /\/api\/training/);
  assert.match(script, /terminalStatuses=/);
  assert.match(script, /alternatives_ready/);
  assert.match(script, /Completed \/ archived campaigns/);
  assert.match(script, /alternatives ready/);
  assert.match(script, /generation complete/);
  assert.match(script, /Earlier setup probes/);
  assert.match(script, /RERUN FOUR ALTERNATIVES/);
  assert.match(script, /filter\(o=>o\.status!=='completed'\)/);
  const snapshot = await (await fetch(`${dashboard.origin}/api/snapshot`)).json();
  assert.equal(snapshot.session.attempts, 3);
  assert.equal(snapshot.failures[0].name, 'keyboard');
  assert.equal(snapshot.novelty.newSource, 1);
  assert.equal(snapshot.novelty.knownLessonSource, 0);
  assert.deepEqual(snapshot.tasks.map(task => task.id).sort(),
    ['keyboard-tabs-dialog-v1', 'trusted-v1']);
  assert.equal(snapshot.tasks.some(task => task.id.startsWith('objective-')), false);
  assert.equal(snapshot.gallery.length, 1);
  assert.equal(snapshot.gallery[0].displayTitle, 'Trusted contract');
  assert.equal(snapshot.gallery[0].taskId, 'trusted-v1');
  assert.equal(snapshot.university.blueprintCount > 0, true);

  const rejected = await fetch(`${dashboard.origin}/api/objectives`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', Origin: 'https://evil.example' },
    body: JSON.stringify({ mode: 'explore', title: 'Bad', prompt: 'Bad' }),
  });
  assert.equal(rejected.status, 403);
  const accepted = await fetch(`${dashboard.origin}/api/objectives`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', Origin: dashboard.origin },
    body: JSON.stringify({ mode: 'explore', title: '<Graph>', prompt: 'Build safely.' }),
  });
  assert.equal(accepted.status, 201);
  assert.equal((await accepted.json()).title, '<Graph>');
  const campaign = await fetch(`${dashboard.origin}/api/campaigns`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', Origin: dashboard.origin },
    body: JSON.stringify({ name: 'Client site', siteType: 'custom', brief: 'Build a client site.', features: [] }),
  });
  assert.equal(campaign.status, 201);
  const campaignBody = await campaign.json();
  assert.equal(campaignBody.status, 'training');
  const alternatives = await fetch(`${dashboard.origin}/api/campaigns/${campaignBody.id}/alternatives`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', Origin: dashboard.origin }, body: '{}',
  });
  assert.equal(alternatives.status, 400);
  assert.match((await alternatives.json()).error, /terminal result/);
  const pauseRejected = await fetch(`${dashboard.origin}/api/training`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', Origin: 'https://evil.example' },
    body: JSON.stringify({ paused: true }),
  });
  assert.equal(pauseRejected.status, 403);
  const pauseAccepted = await fetch(`${dashboard.origin}/api/training`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', Origin: dashboard.origin },
    body: JSON.stringify({ paused: true }),
  });
  assert.equal(pauseAccepted.status, 200);
  const pauseBody = await pauseAccepted.json();
  assert.equal(pauseBody.paused, true);
  assert.equal(pauseBody.stopQwen, false);
  assert.equal((await (await fetch(`${dashboard.origin}/api/snapshot`)).json()).trainingPaused, true);
  const stopQwen = await fetch(`${dashboard.origin}/api/training`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', Origin: dashboard.origin },
    body: JSON.stringify({ paused: true, stopQwen: true }),
  });
  assert.equal(stopQwen.status, 200);
  const stopBody = await stopQwen.json();
  assert.equal(stopBody.paused, true);
  assert.equal(stopBody.stopQwen, true);
  assert.equal(stopBody.reason, 'operator_dashboard_stop_qwen');
  const snap = await (await fetch(`${dashboard.origin}/api/snapshot`)).json();
  assert.equal(snap.trainingPaused, true);
  assert.equal(snap.trainingStopQwen, true);
  const autoplayOff = await fetch(`${dashboard.origin}/api/training`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', Origin: dashboard.origin },
    body: JSON.stringify({ autoplay: false }),
  });
  assert.equal(autoplayOff.status, 200);
  const autoplayBody = await autoplayOff.json();
  assert.equal(autoplayBody.autoplay, false);
  assert.equal(autoplayBody.paused, true);
  assert.equal((await (await fetch(`${dashboard.origin}/api/snapshot`)).json()).trainingAutoplay, false);
  assert.equal((await fetch(`${dashboard.origin}/artifacts/../../state.json/practice/desktop.png`)).status, 404);
});

test('dashboard refuses non-loopback binding', async t => {
  const workDir = await workspace(t);
  await assert.rejects(startDashboard({ workDir, trustedTasks, host: '0.0.0.0', port: 0 }), /literal loopback/);
});
