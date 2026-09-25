import { promises as fs } from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { buildBundle, GYM_MEDIA_FILES, gymMediaDir, outputText, taskProps } from './browser.mjs';
import { createCampaign, listCampaigns, requestCampaignAlternatives } from './coach.mjs';
import { listObjectives, enqueueObjective } from './objectives.mjs';
import { readJson, writeJson } from './gym-core.mjs';
import { masterySnapshot } from './scheduler.mjs';
import { listUniversityTasks, readUniversity, universitySummary } from './course-factory.mjs';

const RUN_ID = /^[0-9]{8}-[a-f0-9]{12}$/;
const STATIC_FILES = new Map([
  ['/', ['dashboard.html', 'text/html; charset=utf-8']],
  ['/dashboard.css', ['dashboard.css', 'text/css; charset=utf-8']],
  ['/dashboard.js', ['dashboard.js', 'text/javascript; charset=utf-8']],
]);

function json(response, status, body) {
  response.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
  response.end(JSON.stringify(body));
}

async function readEvents(workDir) {
  const events = [];
  for (const name of ['events.previous.jsonl', 'events.jsonl']) {
    try {
      const text = await fs.readFile(path.join(workDir, name), 'utf8');
      for (const line of text.split(/\r?\n/)) {
        if (!line.trim()) continue;
        try { events.push(JSON.parse(line)); } catch {}
      }
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
    }
  }
  return events.slice(-4000);
}

async function receipt(workDir, runId) {
  if (!RUN_ID.test(runId)) return null;
  return await readJson(path.join(workDir, 'runs', runId, 'receipt.json'), null);
}

async function taskRows(workDir, state, trustedTasks, events) {
  const curriculum = await masterySnapshot(workDir, state, trustedTasks, events);
  return curriculum.map(row => ({ ...row, passRate: row.recentPassRate }))
    .sort((a, b) => a.passRate - b.passRate || b.attempted - a.attempted);
}

function sessionStats(state) {
  const baseline = state.session?.baseline ?? {};
  return {
    id: state.session?.id ?? null,
    startedAt: state.session?.startedAt ?? state.startedAt ?? null,
    attempts: Math.max(0, state.stats.attempts - (baseline.attempts ?? state.stats.attempts)),
    passed: Math.max(0, state.stats.passed - (baseline.passed ?? state.stats.passed)),
    failed: Math.max(0, state.stats.failed - (baseline.failed ?? state.stats.failed)),
    infrastructureErrors: Math.max(0, state.stats.infrastructureErrors -
      (baseline.infrastructureErrors ?? state.stats.infrastructureErrors)),
  };
}

async function snapshot(workDir, trustedTasks) {
  const state = await readJson(path.join(workDir, 'state.json'), null);
  if (!state) return { status: 'not_started', workDir };
  const trainingControl = await readJson(path.join(workDir, 'training-pause.json'), { paused: false });
  const events = await readEvents(workDir);
  const sessionStartedAt = Date.parse(state.session?.startedAt ?? '');
  const sessionEvents = Number.isFinite(sessionStartedAt)
    ? events.filter(event => Date.parse(event.at ?? '') >= sessionStartedAt)
    : events;
  const failureCounts = new Map();
  const novelty = { newSource: 0, knownLessonSource: 0, noSource: 0 };
  for (const event of sessionEvents) {
    for (const name of event.failedChecks ?? []) failureCounts.set(name, (failureCounts.get(name) ?? 0) + 1);
    if (event.novelty === 'new_source') novelty.newSource++;
    else if (event.novelty === 'known_lesson_source') novelty.knownLessonSource++;
    else if (event.novelty === 'no_source') novelty.noSource++;
  }
  const objectives = await listObjectives(workDir);
  const objectiveById = new Map(objectives.map(item => [item.id, item]));
  const campaigns = await listCampaigns(workDir);
  const universityState = await readUniversity(workDir);
  const universityTasks = await listUniversityTasks(workDir, trustedTasks);
  const allTasks = [...trustedTasks, ...universityTasks];
  const tasks = await taskRows(workDir, state, allTasks, events);
  const campaignRunIds = new Set(campaigns.flatMap(campaign =>
    [
      ...(campaign.alternatives ?? []).map(item => item.runId),
      ...(campaign.alternativeHistory ?? []).flatMap(set =>
        (set.alternatives ?? []).map(item => item.runId)),
    ].filter(Boolean)));
  const ids = [...new Set([...(state.recent ?? []), ...(state.lessons ?? []).map(item => item.runId)])].slice(-80).reverse();
  const candidates = [];
  for (const id of ids) {
    const item = await receipt(workDir, id);
    if (!item?.passed || !item.sourceHash || campaignRunIds.has(id)) continue;
    const objective = item.objectiveId ? objectiveById.get(item.objectiveId) : null;
    const task = allTasks.find(candidate => candidate.id === item.taskId);
    if (objective?.campaignId || (!objective && !task?.qualityProfile)) continue;
    candidates.push({
      runId: id, taskId: item.taskId, at: item.at, passed: item.passed,
      model: item.model, sourceHash: item.sourceHash, novelty: item.novelty ?? null,
      objectiveId: item.objectiveId ?? null, objectiveMode: item.objectiveMode ?? null,
      displayTitle: objective?.title ?? task?.title ?? item.taskId,
      galleryKey: objective ? `objective:${objective.id}` : `task:${item.taskId}`,
      durationMs: item.timings?.totalMs ?? null,
      failure: item.candidateError ?? item.evidence?.flatMap(split => split.errors ?? []).join('; ') ?? null,
      desktop: item.evidence?.[0]?.artifacts?.some(file => file.endsWith('desktop.png'))
        ? `/artifacts/${id}/practice/desktop.png` : null,
      mobile: item.evidence?.[0]?.artifacts?.some(file => file.endsWith('mobile.png'))
        ? `/artifacts/${id}/practice/mobile.png` : null,
      preview: item.sourceHash ? `/preview/${id}` : null,
    });
  }
  const gallery = [];
  const galleryKeys = new Set();
  for (const item of candidates.sort((a, b) => Date.parse(b.at) - Date.parse(a.at))) {
    if (galleryKeys.has(item.galleryKey)) continue;
    galleryKeys.add(item.galleryKey);
    gallery.push(item);
    if (gallery.length >= 12) break;
  }
  return {
    status: state.status,
    trainingPaused: trainingControl.paused === true,
    trainingStopQwen: trainingControl.stopQwen === true,
    trainingAutoplay: trainingControl.autoplay !== false,
    updatedAt: state.updatedAt,
    active: state.active ? {
      taskId: state.active.taskId,
      attempt: state.active.attempt,
      feedback: state.active.feedback ?? '',
      advice: state.active.advice ?? '',
      objectiveMode: state.active.customTask?.objectiveMode ?? null,
    } : null,
    lifetime: state.stats,
    session: sessionStats(state),
    lessons: state.lessons?.filter(item => !item.stale) ?? [],
    tasks,
    university: universitySummary(universityState, tasks),
    scheduler: state.scheduler ?? null,
    failures: [...failureCounts.entries()].map(([name, count]) => ({ name, count }))
      .sort((a, b) => b.count - a.count).slice(0, 12),
    novelty,
    recentEvents: sessionEvents.slice(-30).reverse(),
    gallery,
    objectives,
    campaigns,
    contracts: trustedTasks.map(task => ({ id: task.id, title: task.title, family: task.family })),
    lastError: state.lastError ?? null,
  };
}

export async function startDashboard({ workDir, trustedTasks, port = 4177, host = '127.0.0.1' }) {
  if (host !== '127.0.0.1') throw new Error('Frontend gym dashboard must remain on literal loopback.');
  const staticRoot = path.join(path.dirname(fileURLToPath(import.meta.url)), 'dashboard');
  const previewCache = new Map();
  let origin;
  const server = http.createServer(async (request, response) => {
    try {
      const url = new URL(request.url, origin ?? `http://${host}:${port}`);
      response.setHeader('X-Content-Type-Options', 'nosniff');
      response.setHeader('Referrer-Policy', 'no-referrer');
      response.setHeader('X-Frame-Options', 'SAMEORIGIN');
      if (request.method === 'GET' && STATIC_FILES.has(url.pathname)) {
        const [name, type] = STATIC_FILES.get(url.pathname);
        response.writeHead(200, {
          'Content-Type': type,
          'Cache-Control': 'no-store',
          'Content-Security-Policy': "default-src 'self'; connect-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; frame-src 'self'; object-src 'none'; base-uri 'none'; form-action 'self'",
        });
        response.end(await fs.readFile(path.join(staticRoot, name)));
        return;
      }
      if (request.method === 'GET' && url.pathname === '/api/snapshot') {
        json(response, 200, await snapshot(workDir, trustedTasks));
        return;
      }
      if (request.method === 'POST' && url.pathname === '/api/objectives') {
        if (request.headers.origin !== origin || !request.headers['content-type']?.startsWith('application/json')) {
          json(response, 403, { error: 'Dashboard objective submissions require same-origin JSON.' });
          return;
        }
        let body = '';
        for await (const chunk of request) {
          body += chunk;
          if (body.length > 8192) throw new Error('Objective request is too large.');
        }
        try {
          json(response, 201, await enqueueObjective(workDir, JSON.parse(body), trustedTasks));
        } catch (error) {
          json(response, 400, { error: error.message });
        }
        return;
      }
      if (request.method === 'POST' && url.pathname === '/api/campaigns') {
        if (request.headers.origin !== origin || !request.headers['content-type']?.startsWith('application/json')) {
          json(response, 403, { error: 'Coach submissions require same-origin JSON.' });
          return;
        }
        let body = '';
        for await (const chunk of request) {
          body += chunk;
          if (body.length > 16_384) throw new Error('Client brief is too large.');
        }
        try {
          json(response, 201, await createCampaign(workDir, JSON.parse(body), trustedTasks));
        } catch (error) {
          json(response, 400, { error: error.message });
        }
        return;
      }
      const alternativesMatch = /^\/api\/campaigns\/([a-f0-9]{12})\/alternatives$/.exec(url.pathname);
      if (request.method === 'POST' && alternativesMatch) {
        if (request.headers.origin !== origin || !request.headers['content-type']?.startsWith('application/json')) {
          json(response, 403, { error: 'Alternative controls require same-origin JSON.' });
          return;
        }
        try {
          json(response, 202, await requestCampaignAlternatives(workDir, alternativesMatch[1], trustedTasks));
        } catch (error) {
          json(response, 400, { error: error.message });
        }
        return;
      }
      if (request.method === 'POST' && url.pathname === '/api/training') {
        if (request.headers.origin !== origin || !request.headers['content-type']?.startsWith('application/json')) {
          json(response, 403, { error: 'Training controls require same-origin JSON.' });
          return;
        }
        let body = '';
        for await (const chunk of request) {
          body += chunk;
          if (body.length > 256) throw new Error('Training control request is too large.');
        }
        const command = JSON.parse(body);
        if (typeof command.paused !== 'boolean' && typeof command.autoplay !== 'boolean') {
          json(response, 400, { error: 'Training control requires paused or autoplay.' });
          return;
        }
        const existing = await readJson(path.join(workDir, 'training-pause.json'), {
          paused: false, stopQwen: false, autoplay: true,
        });
        const paused = typeof command.paused === 'boolean' ? command.paused : Boolean(existing.paused);
        const autoplay = typeof command.autoplay === 'boolean' ? command.autoplay : existing.autoplay !== false;
        const stopQwen = paused && (typeof command.stopQwen === 'boolean' ? command.stopQwen : Boolean(existing.stopQwen));
        const control = {
          paused,
          stopQwen,
          autoplay,
          updatedAt: new Date().toISOString(),
          reason: typeof command.autoplay === 'boolean' && typeof command.paused !== 'boolean'
            ? (autoplay ? 'operator_autoplay_on' : 'operator_autoplay_off')
            : paused
              ? (stopQwen ? 'operator_dashboard_stop_qwen' : 'operator_dashboard')
              : 'operator_resume',
        };
        await writeJson(path.join(workDir, 'training-pause.json'), control);
        json(response, 200, control);
        return;
      }
      const artifactMatch = /^\/artifacts\/([^/]+)\/(practice|transfer)\/(desktop|mobile)\.png$/.exec(url.pathname);
      if (request.method === 'GET' && artifactMatch && RUN_ID.test(artifactMatch[1])) {
        const file = path.join(workDir, 'runs', artifactMatch[1], artifactMatch[2], `${artifactMatch[3]}.png`);
        response.writeHead(200, { 'Content-Type': 'image/png', 'Cache-Control': 'no-store' });
        response.end(await fs.readFile(file));
        return;
      }
      const previewMatch = /^\/preview\/([^/]+)(?:\/(bundle\.js|bundle\.css|props\.js))?$/.exec(url.pathname);
      if (request.method === 'GET' && previewMatch && RUN_ID.test(previewMatch[1])) {
        const runId = previewMatch[1];
        let built = previewCache.get(runId);
        if (!built) {
          const source = await readJson(path.join(workDir, 'runs', runId, 'source.json'), null);
          const runReceipt = await receipt(workDir, runId);
          if (!source || !runReceipt) throw new Error('Preview source is unavailable.');
          const bundle = await buildBundle(source);
          const contractId = runReceipt.contractTaskId ?? runReceipt.taskId;
          let props = { objectiveTitle: runReceipt.taskId, objectiveSeed: runReceipt.seeds?.[0] ?? 1 };
          if (!runReceipt.objectiveMode || runReceipt.objectiveMode === 'qualify') {
            props = taskProps(contractId, runReceipt.seeds?.[0] ?? 1);
          }
          built = { js: outputText(bundle, '.js'), css: outputText(bundle, '.css'), props };
          previewCache.set(runId, built);
          if (previewCache.size > 12) previewCache.delete(previewCache.keys().next().value);
        }
        const asset = previewMatch[2];
        response.setHeader('Cache-Control', 'no-store');
        response.setHeader('Content-Security-Policy',
          "default-src 'none'; connect-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'none'; object-src 'none'; frame-src 'none'; worker-src 'none'; form-action 'none'; base-uri 'none'");
        if (asset === 'bundle.js') {
          response.writeHead(200, { 'Content-Type': 'text/javascript; charset=utf-8' });
          response.end(built.js);
        } else if (asset === 'bundle.css') {
          response.writeHead(200, { 'Content-Type': 'text/css; charset=utf-8' });
          response.end(built.css);
        } else if (asset === 'props.js') {
          response.writeHead(200, { 'Content-Type': 'text/javascript; charset=utf-8' });
          response.end(`window.__GODBRAIN_TASK_PROPS__=${JSON.stringify(built.props).replace(/</g, '\\u003c')};`);
        } else {
          response.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
          response.end(`<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><link rel="stylesheet" href="/preview/${runId}/bundle.css"></head><body><div id="root"></div><script src="/preview/${runId}/props.js"></script><script src="/preview/${runId}/bundle.js"></script></body></html>`);
        }
        return;
      }
      const mediaName = request.method === 'GET' ? GYM_MEDIA_FILES.get(url.pathname) : null;
      if (mediaName) {
        try {
          const media = await fs.readFile(path.join(gymMediaDir(), mediaName));
          response.writeHead(200, { 'Content-Type': 'image/jpeg', 'Cache-Control': 'public, max-age=86400' });
          response.end(media);
          return;
        } catch {
          // Missing local photo falls through to not found.
        }
      }
      response.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
      response.end('not found');
    } catch (error) {
      if (!response.headersSent) json(response, 500, { error: error.message });
      else response.destroy();
    }
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(port, host, resolve);
  });
  origin = `http://${host}:${server.address().port}`;
  return {
    origin,
    close: () => new Promise(resolve => {
      server.closeAllConnections?.();
      server.close(resolve);
    }),
  };
}
