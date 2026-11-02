import assert from 'node:assert/strict';
import { promises as fs } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { chromium } from 'playwright';
import { advanceCampaigns, createCampaign, listCampaigns, regenerateCampaign } from './coach.mjs';
import { startDashboard } from './dashboard.mjs';
import { hashFiles, newState, readJson, runPractice, writeJson } from './gym-core.mjs';
import { completeObjective, enqueueObjective, listObjectives } from './objectives.mjs';

const contracts = [{
  id: 'trusted-v1', family: 'marketing-sites', title: 'Trusted',
  brief: 'A complete browser-qualified frontend.', docs: [],
}];
const brief = { name: 'Portfolio', siteType: 'portfolio', brief: 'A project screenshot gallery.', features: [] };
const lab = path.dirname(fileURLToPath(import.meta.url));

async function workspace(t) {
  const root = path.join(lab, 'work', 'tests');
  await fs.mkdir(root, { recursive: true });
  const dir = await fs.mkdtemp(path.join(root, 'builder-'));
  t.after(() => fs.rm(dir, { recursive: true, force: true }));
  return dir;
}

async function passingSource(workDir, runId) {
  const source = {
    'App.jsx': 'export default function App(){return <main><h1>Portfolio</h1><p>Saved project gallery</p></main>}',
    'styles.css': 'body{margin:0;color:#eee;background:#111}',
  };
  const dir = path.join(workDir, 'runs', runId);
  await fs.mkdir(dir, { recursive: true });
  await writeJson(path.join(dir, 'source.json'), source);
  await writeJson(path.join(dir, 'receipt.json'), {
    runId, owner: 'godbrain-frontend-gym', sourceHash: hashFiles(source), passed: true, objectiveMode: 'explore',
    at: new Date().toISOString(), evidence: [{ passed: true }, { passed: true }],
  });
}

test('completed websites stay idle and manual regeneration retains the passing version', async t => {
  const workDir = await workspace(t);
  const runId = '00000001-aaaaaaaaaaaa';
  await passingSource(workDir, runId);
  await writeJson(path.join(workDir, 'campaigns.json'), { version: 1, items: [{
    id: 'aaaaaaaaaaaa', status: 'delivered', createdAt: new Date().toISOString(),
    brief, capabilities: [], buildMode: 'website', buildGeneration: 1,
    previewRunId: runId, assemblyRunIds: [runId], assemblyStage: 'polish',
  }] });
  for (let i = 0; i < 3; i++) await advanceCampaigns(workDir, contracts);
  assert.equal((await listObjectives(workDir)).length, 0);
  const requests = await Promise.allSettled([
    regenerateCampaign(workDir, 'aaaaaaaaaaaa', contracts),
    regenerateCampaign(workDir, 'aaaaaaaaaaaa', contracts),
  ]);
  assert.equal(requests.filter(row => row.status === 'fulfilled').length, 1);
  const stored = (await listCampaigns(workDir))[0];
  assert.equal(stored.buildGeneration, 2);
  assert.equal(stored.buildHistory[0].previewRunId, runId);
  const queue = await listObjectives(workDir);
  assert.equal(queue.length, 1);
  assert.equal(queue[0].campaignStage, 'assembly-shell');
  assert.match(queue[0].stableKey, /site-g2/);
});

test('legacy repeat retirement preserves the last completed set and cancels only its unwanted successor', async t => {
  const workDir = await workspace(t);
  const campaignId = 'bbbbbbbbbbbb';
  const pending = await enqueueObjective(workDir, {
    mode: 'explore', title: 'Unwanted repeat', prompt: 'Old repeating work.',
  }, contracts, { campaignId, campaignStage: 'alternative-styles' });
  const manual = await createCampaign(workDir, { ...brief, name: 'Keep my manual site' }, contracts);
  const campaigns = await readJson(path.join(workDir, 'campaigns.json'));
  campaigns.items.push({
    id: campaignId, status: 'showcasing', createdAt: new Date().toISOString(), brief,
    capabilities: [], alternativeGeneration: 3,
    alternatives: [{ id: 'one', title: 'New attempt', status: 'qualifying', styleObjectiveId: pending.id }],
    alternativeHistory: [{
      generation: 2, status: 'alternatives_ready',
      alternatives: [{ id: 'one', title: 'Saved', status: 'ready', runId: '00000001-aaaaaaaaaaaa' }],
    }],
  });
  await writeJson(path.join(workDir, 'campaigns.json'), campaigns);
  await writeJson(path.join(workDir, 'repeat-campaign.json'), { campaignId });
  for (let i = 0; i < 3; i++) await advanceCampaigns(workDir, contracts);
  const saved = (await listCampaigns(workDir)).find(item => item.id === campaignId);
  assert.equal(saved.status, 'alternatives_ready');
  assert.equal(saved.alternativeGeneration, 2);
  assert.equal(saved.alternativeHistory.at(-1).status, 'cancelled');
  const queue = await listObjectives(workDir);
  assert.equal(queue.find(item => item.id === pending.id).outcome, 'cancelled');
  assert.equal(queue.find(item => item.campaignId === manual.id).status, 'queued');
  assert.equal(queue.length, 2);
  assert.equal((await readJson(path.join(workDir, 'repeat-campaign.json'))).campaignId, null);
});

test('regenerating an archived website cannot queue a duplicate active project', async t => {
  const workDir = await workspace(t);
  const older = await createCampaign(workDir, brief, contracts);
  const campaigns = await readJson(path.join(workDir, 'campaigns.json'));
  campaigns.items[0].status = 'delivered';
  campaigns.items[0].createdAt = '2020-01-01T00:00:00Z';
  await writeJson(path.join(workDir, 'campaigns.json'), campaigns);
  const newer = await createCampaign(workDir, { ...brief, name: ' PORTFOLIO ' }, contracts);
  const before = await fs.readFile(path.join(workDir, 'campaigns.json'), 'utf8');
  await assert.rejects(regenerateCampaign(workDir, older.id, contracts), /active campaign named/);
  assert.equal(await fs.readFile(path.join(workDir, 'campaigns.json'), 'utf8'), before);
  assert.equal((await listCampaigns(workDir)).find(item => item.id === newer.id).status, 'assembling');
  assert.equal((await listObjectives(workDir)).length, 2);
});

test('passing website and alternative artifacts survive more than ten failed regenerations', async t => {
  const workDir = await workspace(t);
  const saved = ['00000001-bbbbbbbbbbbb', '00000002-bbbbbbbbbbbb'];
  for (const id of saved) await passingSource(workDir, id);
  await writeJson(path.join(workDir, 'campaigns.json'), { version: 1, items: [{
    id: 'aaaaaaaaaaaa', status: 'delivered', createdAt: '2020-01-01T00:00:00Z',
    brief, capabilities: [], buildMode: 'website', buildGeneration: 1,
    previewRunId: saved[0], assemblyRunIds: [saved[0]],
    alternatives: [{ status: 'ready', runId: saved[1] }],
  }] });
  for (let i = 0; i < 12; i++) {
    const campaign = await regenerateCampaign(workDir, 'aaaaaaaaaaaa', contracts);
    await completeObjective(workDir, campaign.assemblyObjectiveId, { runId: 'failed-shell' }, 'attempt_limit');
    const recovery = (await advanceCampaigns(workDir, contracts))[0];
    await completeObjective(workDir, recovery.assemblyObjectiveId, { runId: 'failed-recovery' }, 'attempt_limit');
    await advanceCampaigns(workDir, contracts);
  }
  const stored = (await listCampaigns(workDir))[0];
  assert.equal(stored.buildHistory[0].previewRunId, saved[0]);
  assert.equal(stored.buildHistory.length, 11);
  assert.equal(stored.alternativeHistory[0].alternatives[0].runId, saved[1]);
  await runPractice({
    workDir, endpoint: 'http://127.0.0.1:9998/v1', rounds: 1, maxAttempts: 1,
    intervalMs: 0, tutorEvery: 0, keepRuns: 1,
    nextTask: async () => ({ ...contracts[0], objectiveId: 'retention', retainLesson: false }),
  }, {
    tasks: contracts, evaluatorVersion: 'test',
    complete: async () => ({
      text: JSON.stringify({ files: {
        'App.jsx': 'export default function App(){return <main>Retention</main>}', 'styles.css': '',
      } }), model: 'test', finishReason: 'stop',
    }),
    evaluate: async request => ({
      taskId: request.taskId, seed: request.seed, passed: true,
      checks: [{ name: 'synthetic-browser-check', passed: true }], errors: [], artifacts: [],
    }),
  });
  for (const id of saved) assert.ok(await readJson(path.join(workDir, 'runs', id, 'source.json')));
});

test('a manually queued client job runs with course autoplay off', async t => {
  const workDir = await workspace(t);
  const saved = ['00000001-bbbbbbbbbbbb', '00000002-bbbbbbbbbbbb', '00000003-bbbbbbbbbbbb'];
  for (const id of saved) await passingSource(workDir, id);
  await writeJson(path.join(workDir, 'campaigns.json'), { items: [{
    previewRunId: saved[0], buildHistory: [{ previewRunId: saved[1] }],
    alternativeHistory: [{ alternatives: [{ runId: saved[2] }] }],
  }] });
  let queued = true;
  let generated = 0;
  await runPractice({
    workDir, endpoint: 'http://127.0.0.1:9998/v1', rounds: 1, maxAttempts: 1,
    intervalMs: 0, tutorEvery: 0, autoplayEnabled: async () => false,
    nextTask: async () => {
      if (!queued) return null;
      queued = false;
      return { ...contracts[0], id: 'objective-manual', objectiveId: 'manual', retainLesson: false };
    },
    selectTask: async () => { throw new Error('Course must not start.'); },
  }, {
    tasks: contracts, evaluatorVersion: 'test',
    complete: async () => {
      generated++;
      return { text: JSON.stringify({ files: {
        'App.jsx': 'export default function App(){return <main>Manual</main>}', 'styles.css': '',
      } }), model: 'test', finishReason: 'stop' };
    },
    evaluate: async request => ({
      taskId: request.taskId, seed: request.seed, passed: true,
      checks: [{ name: 'synthetic-browser-check', passed: true }], errors: [], artifacts: [],
    }),
  });
  assert.equal(generated, 1);
  for (const id of saved) {
    assert.ok(await readJson(path.join(workDir, 'runs', id, 'source.json')));
  }
});

test('builder endpoints require same-origin empty JSON and report database failures', async t => {
  const workDir = await workspace(t);
  await writeJson(path.join(workDir, 'state.json'), newState());
  await writeJson(path.join(workDir, 'campaigns.json'), { items: [{
    id: 'dddddddddddd', status: 'alternatives_ready', brief, capabilities: [],
    assemblyRunIds: ['00000002-bbbbbbbbbbbb'],
    alternatives: [{ status: 'ready', runId: '00000002-bbbbbbbbbbbb' }],
  }] });
  let calls = 0;
  const dashboard = await startDashboard({
    workDir, trustedTasks: contracts, port: 0,
    databaseCheck: async () => { calls++; throw new Error('Synthetic database outage.'); },
  });
  t.after(() => dashboard.close());
  const url = `${dashboard.origin}/api/builder/database-check`;
  const saved = await (await fetch(`${dashboard.origin}/api/snapshot`)).json();
  assert.match(saved.campaigns[0].alternatives[0].preview.error, /unavailable/);
  assert.equal(saved.campaigns[0].buildPreview, null);
  const denied = await fetch(url, { method: 'POST', headers: { Origin: 'https://example.test', 'Content-Type': 'application/json' }, body: '{}' });
  assert.equal(denied.status, 403);
  const headers = { Origin: dashboard.origin, 'Content-Type': 'application/json' };
  const invalid = await fetch(url, { method: 'POST', headers, body: '{"database":"godbrain"}' });
  assert.equal(invalid.status, 400);
  assert.equal(calls, 0);
  const failed = await fetch(url, { method: 'POST', headers, body: '{}' });
  assert.equal(failed.status, 500);
  assert.equal((await readJson(path.join(workDir, 'builder-db-last.json'))).ok, 0);
});

test('a saved course resumes after a manual site without losing its checkpoint', async t => {
  const workDir = await workspace(t);
  const state = newState();
  state.active = {
    taskId: contracts[0].id, attempt: 0, files: null, feedback: '', advice: '',
    trainSeed: 11, holdoutSeed: 1009,
  };
  await writeJson(path.join(workDir, 'state.json'), state);
  let autoplay = false;
  let queued = true;
  const evaluated = [];
  await runPractice({
    workDir, endpoint: 'http://127.0.0.1:9998/v1', rounds: 2, maxAttempts: 1,
    intervalMs: 0, tutorEvery: 0, autoplayEnabled: async () => autoplay,
    nextTask: async () => {
      if (!queued) return null;
      queued = false;
      return { ...contracts[0], id: 'objective-client', objectiveId: 'client', retainLesson: false };
    },
    selectTask: async () => { throw new Error('The saved course must resume directly.'); },
    onProgress: () => { autoplay = true; },
  }, {
    tasks: contracts, evaluatorVersion: 'test',
    complete: async () => ({
      text: JSON.stringify({ files: {
        'App.jsx': 'export default function App(){return <main>Resume</main>}', 'styles.css': '',
      } }), model: 'test', finishReason: 'stop',
    }),
    evaluate: async request => {
      evaluated.push({ task: request.taskId, seed: request.seed });
      return {
        taskId: request.taskId, seed: request.seed, passed: true,
        checks: [{ name: 'synthetic-browser-check', passed: true }], errors: [], artifacts: [],
      };
    },
  });
  assert.deepEqual(evaluated.map(item => item.task), ['objective-client', 'objective-client', contracts[0].id, contracts[0].id]);
  assert.equal(evaluated[2].seed, 11);
  assert.equal((await readJson(path.join(workDir, 'state.json'))).suspendedCourse, null);
});

test('browser exposes retained previews, manual regeneration and the renamed builder', async t => {
  const workDir = await workspace(t);
  const runId = '00000001-aaaaaaaaaaaa';
  await passingSource(workDir, runId);
  await writeJson(path.join(workDir, 'state.json'), newState());
  await writeJson(path.join(workDir, 'campaigns.json'), { version: 1, items: [{
    id: 'cccccccccccc', status: 'delivered', createdAt: new Date().toISOString(),
    brief, capabilities: [], buildMode: 'website', buildGeneration: 1,
    previewRunId: runId, assemblyRunIds: [runId], assemblyStage: 'polish',
  }, {
    id: 'eeeeeeeeeeee', status: 'alternatives_ready', createdAt: new Date().toISOString(),
    brief: { ...brief, name: 'Saved Trippus' }, capabilities: [], alternativeGeneration: 1,
    alternatives: [{ id: 'one', title: 'Saved direction', status: 'ready', runId }],
  }] });
  const dashboard = await startDashboard({ workDir, trustedTasks: contracts, port: 0 });
  const browser = await chromium.launch({
    executablePath: process.env.GODBRAIN_BROWSER || 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
    headless: true, args: ['--disable-gpu'],
  });
  t.after(async () => { await browser.close(); await dashboard.close(); });
  const page = await browser.newPage();
  await page.goto(dashboard.origin);
  await page.getByRole('heading', { name: 'CLIENT WEB SITE BUILDER', exact: true }).waitFor();
  assert.equal(await page.getByRole('button', { name: 'START GENERATION', exact: true }).count(), 1);
  await page.getByRole('button', { name: 'OPEN SAVED WEBSITE', exact: true }).waitFor();
  const saved = page.locator('#campaigns .campaign').filter({ has: page.getByText('Saved Trippus', { exact: true }) });
  await saved.getByRole('button', { name: 'Saved direction', exact: true }).click();
  await page.frameLocator('#previewFrame').getByRole('heading', { name: 'Portfolio', exact: true }).waitFor();
  await page.locator('#previewDialog').evaluate(node => node.close());
  const portfolio = page.locator('#campaigns .campaign').filter({ has: page.getByText('Portfolio', { exact: true }) });
  await portfolio.getByRole('button', { name: 'REGENERATE', exact: true }).click();
  await page.getByText('Previous website versions (1)', { exact: true }).waitFor();
  await page.getByText('Previous website versions (1)', { exact: true }).click();
  const historyStayedOpen = await page.evaluate(() => new Promise((resolve, reject) => {
    const timer = setTimeout(() => { observer.disconnect(); reject(new Error('Dashboard did not refresh.')); }, 5000);
    const observer = new MutationObserver(() => {
      observer.disconnect();
      clearTimeout(timer);
      resolve(document.querySelector('details[data-campaign-history="cccccccccccc:build"]').open);
    });
    observer.observe(document.getElementById('campaigns'), { childList: true });
  }));
  assert.equal(historyStayedOpen, true);
  assert.equal((await listObjectives(workDir)).length, 1);
  assert.equal((await page.request.get(`${dashboard.origin}/preview/${runId}`)).status(), 200);
  await page.getByLabel('Project name', { exact: true }).fill('Another portfolio');
  await page.getByLabel('Client request', { exact: true }).fill('Build my project gallery.');
  await page.getByRole('button', { name: 'START GENERATION', exact: true }).click();
  await page.getByText(/This generation runs once/).waitFor();
  assert.equal((await listObjectives(workDir)).length, 2);
  assert.equal((await listObjectives(workDir)).every(item => item.campaignStage === 'assembly-shell'), true);
});
