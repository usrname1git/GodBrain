import { randomUUID } from 'node:crypto';
import { promises as fs } from 'node:fs';
import path from 'node:path';
import { readJson, writeJson } from './gym-core.mjs';
import { getReference } from './references.mjs';

const MAX_OBJECTIVES = 100;
const MAX_TEXT = 1200;
const MODES = new Set(['explore', 'qualify']);
const FILE_MODES = new Set(['both', 'app', 'styles']);
const EVALUATION_PROFILES = new Set(['full', 'structure-draft']);
const STYLES_MAX_TOKENS = 4096;
const DRAFT_CSS = '*{box-sizing:border-box}body{margin:0;font:16px/1.5 system-ui,sans-serif;color:#132238}header,main,footer,section{display:block}button,input,select{font:inherit}';
let transactionTail = Promise.resolve();

function transaction(action) {
  const current = transactionTail.then(action);
  transactionTail = current.catch(() => {});
  return current;
}

function boundedText(value, name, required = false) {
  const text = String(value ?? '').trim();
  if (required && !text) throw new Error(`${name} is required.`);
  if (text.length > MAX_TEXT || text.includes('\0')) throw new Error(`${name} is too long or invalid.`);
  return text;
}

export function validateObjective(input, trustedTasks) {
  if (!input || Array.isArray(input) || typeof input !== 'object') throw new Error('Objective must be an object.');
  const mode = String(input.mode ?? '').toLowerCase();
  if (!MODES.has(mode)) throw new Error('Objective mode must be explore or qualify.');
  const title = boundedText(input.title, 'Title', true).slice(0, 120);
  const prompt = boundedText(input.prompt, 'Prompt', true);
  const styleReference = boundedText(input.styleReference, 'Style reference');
  let contractTaskId = boundedText(input.contractTaskId, 'Verifier contract');
  if (mode === 'qualify') {
    if (!trustedTasks.some(task => task.id === contractTaskId)) {
      throw new Error('Qualify mode requires an existing trusted verifier contract.');
    }
  } else {
    contractTaskId = '';
  }
  return { mode, title, prompt, styleReference, contractTaskId };
}

async function readQueue(workDir) {
  return await readJson(path.join(workDir, 'objectives.json'), { version: 1, items: [] });
}

export async function enqueueObjective(workDir, input, trustedTasks, metadata = {}) {
  const objective = validateObjective(input, trustedTasks);
  return transaction(async () => {
    const queue = await readQueue(workDir);
    if (queue.version !== 1 || !Array.isArray(queue.items)) throw new Error('Objective queue is damaged.');
    const stableKey = String(metadata.stableKey ?? '');
    if (stableKey && (!/^[a-z0-9:_-]{1,160}$/i.test(stableKey))) throw new Error('Invalid objective stable key.');
    if (metadata.maxTokens != null &&
        (!Number.isSafeInteger(metadata.maxTokens) || metadata.maxTokens < 1 || metadata.maxTokens > 8192)) {
      throw new Error('Invalid objective token budget.');
    }
    if (metadata.initialRunId != null && !/^[0-9]{8}-[a-f0-9]{12}$/.test(metadata.initialRunId)) {
      throw new Error('Invalid objective seed run.');
    }
    const fileMode = metadata.fileMode ?? 'both';
    const evaluationProfile = metadata.evaluationProfile ?? 'full';
    if (!FILE_MODES.has(fileMode)) throw new Error('Invalid objective file mode.');
    if (!EVALUATION_PROFILES.has(evaluationProfile)) throw new Error('Invalid objective evaluation profile.');
    if (metadata.templateTaskId != null &&
        !trustedTasks.some(task => task.id === metadata.templateTaskId)) {
      throw new Error('Unknown trusted objective template.');
    }
    if (fileMode === 'styles' && !metadata.initialRunId && !metadata.templateTaskId) {
      throw new Error('A styles-only objective requires a seed run or trusted template.');
    }
    if (metadata.variantId != null && !/^[a-z0-9-]{1,80}$/.test(metadata.variantId)) {
      throw new Error('Invalid objective variant id.');
    }
    if (stableKey) {
      const existing = queue.items.find(item => item.stableKey === stableKey);
      if (existing) return existing;
    }
    if (queue.items.length >= MAX_OBJECTIVES) {
      const done = queue.items.filter(item => item.status === 'completed');
      if (done.length) {
        const archive = path.join(workDir, 'objectives-archive.jsonl');
        await fs.appendFile(archive, done.map(item => JSON.stringify(item)).join('\n') + '\n');
        queue.items = queue.items.filter(item => item.status !== 'completed');
      }
    }
    if (queue.items.length >= MAX_OBJECTIVES) {
      throw new Error(`Objective queue capacity (${MAX_OBJECTIVES}) reached; finish or archive existing work first.`);
    }
    const item = {
      id: randomUUID().replaceAll('-', '').slice(0, 12),
      ...objective,
      stableKey: stableKey || null,
      campaignId: metadata.campaignId ?? null,
      campaignStage: metadata.campaignStage ?? null,
      maxTokens: metadata.maxTokens ?? null,
      initialRunId: metadata.initialRunId ?? null,
      templateTaskId: metadata.templateTaskId ?? null,
      fileMode,
      evaluationProfile,
      variantId: metadata.variantId ?? null,
      status: 'queued',
      createdAt: new Date().toISOString(),
      startedAt: null,
      completedAt: null,
      runIds: [],
      outcome: null,
    };
    queue.items.push(item);
    await writeJson(path.join(workDir, 'objectives.json'), queue);
    return item;
  });
}

export async function listObjectives(workDir) {
  const queue = await readQueue(workDir);
  return queue.items ?? [];
}

export async function objectiveIsTerminal(workDir, objectiveId) {
  if (!objectiveId) return false;
  const queue = await readQueue(workDir);
  const item = queue.items.find(candidate => candidate.id === objectiveId);
  return item?.status === 'completed';
}

export async function claimObjective(workDir, trustedTasks) {
  return transaction(async () => {
    const queue = await readQueue(workDir);
    const item = queue.items.find(candidate => candidate.status === 'running') ??
      queue.items.find(candidate => candidate.status === 'queued');
    if (!item) return null;
    const valid = validateObjective(item, trustedTasks);
    if (item.status === 'queued') {
      item.status = 'running';
      item.startedAt = new Date().toISOString();
      await writeJson(path.join(workDir, 'objectives.json'), queue);
    }
    const base = valid.mode === 'qualify'
      ? trustedTasks.find(task => task.id === valid.contractTaskId)
      : null;
    const style = valid.styleReference ? `Style inspiration: ${valid.styleReference}` : '';
    let initialFiles = null;
    if (item.initialRunId) {
      if (!/^[0-9]{8}-[a-f0-9]{12}$/.test(item.initialRunId)) throw new Error('Objective seed run is invalid.');
      initialFiles = await readJson(path.join(workDir, 'runs', item.initialRunId, 'source.json'), null);
      if (!initialFiles) throw new Error('Objective seed source is unavailable.');
    } else if (item.templateTaskId) {
      initialFiles = getReference(item.templateTaskId);
    } else if (item.fileMode === 'app') {
      initialFiles = { 'App.jsx': '', 'styles.css': DRAFT_CSS };
    }
    return {
      id: `objective-${item.id}`,
      objectiveId: item.id,
      family: base?.family ?? 'custom-exploration',
      title: valid.title,
      docs: base?.docs ?? [],
      baseTaskId: base?.id ?? null,
      qualityProfile: base?.qualityProfile ?? null,
      objectiveMode: valid.mode,
      retainLesson: valid.mode === 'qualify' && item.evaluationProfile !== 'structure-draft',
      // The local Qwen endpoint has an 8K total context; leave room for the
      // brief, repair feedback, and the previous malformed response.
      maxTokens: item.maxTokens == null
        ? null
        : Math.min(item.maxTokens, item.fileMode === 'styles' ? STYLES_MAX_TOKENS : 4096),
      initialFiles,
      fileMode: item.fileMode ?? 'both',
      evaluationProfile: item.evaluationProfile ?? 'full',
      variantId: item.variantId ?? null,
      brief: [
        valid.prompt,
        style,
        base
          ? `Trusted functional contract (must still pass exactly):\n${base.brief}`
          : 'This is an exploratory creation. Build a complete, useful frontend with visible content, responsive layout, and real interactions. Generic browser safety and rendering checks apply; this does not qualify a reusable lesson.',
      ].filter(Boolean).join('\n\n'),
    };
  });
}

export async function completeObjective(workDir, objectiveId, run, outcome) {
  if (!objectiveId) return;
  return transaction(async () => {
    const queue = await readQueue(workDir);
    const item = queue.items.find(candidate => candidate.id === objectiveId);
    if (!item) return;
    if (item.status === 'completed') return;
    item.runIds = [...new Set([...(item.runIds ?? []), run.runId])].slice(-20);
    item.outcome = outcome;
    if (outcome === 'passed' || outcome === 'attempt_limit') {
      item.status = 'completed';
      item.completedAt = new Date().toISOString();
    }

    await writeJson(path.join(workDir, 'objectives.json'), queue);
  });
}

export async function cancelObjective(workDir, objectiveId, reason) {
  if (!objectiveId) return;
  return transaction(async () => {
    const queue = await readQueue(workDir);
    const item = queue.items.find(candidate => candidate.id === objectiveId);
    if (!item || item.status === 'completed') return;
    item.status = 'completed';
    item.outcome = 'cancelled';
    item.completedAt = new Date().toISOString();
    item.cancelReason = boundedText(reason, 'Cancellation reason', true);
    await writeJson(path.join(workDir, 'objectives.json'), queue);
  });
}
