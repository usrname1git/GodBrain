import { promises as fs } from 'node:fs';
import path from 'node:path';
import { evaluatorFamily } from './gym-core.mjs';

const WINDOW = 40;
const MIN_MASTERY_SAMPLES = 20;
const MASTERY_RATE = 0.95;
const UNIVERSITY_REPLAN_HINTS = Object.freeze([
  'Rebuild from the typed prop contract first. Render every required seeded value before adding optional presentation details.',
  'Use a minimal semantic shell: header and generated navigation, hero and CTAs, four generated sections, proof points, footer, then the responsive Menu state.',
  'Write the AppProps type before JSX and keep the implementation compact. Treat object arrays as objects and map their named fields directly.',
]);

async function recentEvents(workDir) {
  const byTask = new Map();
  for (const name of ['events.previous.jsonl', 'events.jsonl']) {
    try {
      const text = await fs.readFile(path.join(workDir, name), 'utf8');
      for (const line of text.split(/\r?\n/)) {
        if (!line.trim()) continue;
        try {
          const event = JSON.parse(line);
          if (!['exercise_passed', 'attempt_failed', 'attempt_parse_failed'].includes(event.type) || !event.taskId) continue;
          const events = byTask.get(event.taskId) ?? [];
          events.push(event);
          if (events.length > WINDOW) events.shift();
          byTask.set(event.taskId, events);
        } catch {}
      }
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
    }
  }
  return [...byTask.values()].flat();
}

export function classifyMastery(events, state, tasks) {
  return tasks.map(task => {
    const allTaskEvents = events.filter(event => event.taskId === task.id);
    const epoch = task.university?.retargetedAt;
    const sinceExam = epoch
      ? allTaskEvents.filter(event => typeof event.at === 'string' && event.at >= epoch)
      : allTaskEvents;
    const latestEvaluatorVersion = [...sinceExam].reverse()
      .find(event => typeof event.evaluatorVersion === 'string' && event.evaluatorVersion)?.evaluatorVersion;
    const currentFamily = evaluatorFamily(latestEvaluatorVersion);
    const currentEvents = currentFamily
      ? sinceExam.filter(event => evaluatorFamily(event.evaluatorVersion) === currentFamily)
      : sinceExam;
    const taskEvents = currentEvents.slice(-WINDOW);
    const passed = taskEvents.filter(event => event.type === 'exercise_passed');
    const failed = taskEvents.length - passed.length;
    const passRate = taskEvents.length ? passed.length / taskEvents.length : 0;
    const distinctPassingSources = new Set(passed.map(event => event.sourceHash).filter(Boolean)).size;
    const measuredMastery = taskEvents.length >= MIN_MASTERY_SAMPLES &&
      passRate >= MASTERY_RATE && distinctPassingSources >= 2;
    const collapsed = taskEvents.length >= MIN_MASTERY_SAMPLES && passRate < 0.5;
    const mastered = measuredMastery ||
      (task.university?.status === 'mastered' && !collapsed);
    return {
      id: task.id,
      title: task.title,
      family: task.family,
      qualityProfile: task.qualityProfile ?? null,
      baseTaskId: task.baseTaskId ?? null,
      university: task.university ?? null,
      attempted: state.stats.byTask[task.id]?.attempted ?? 0,
      passed: state.stats.byTask[task.id]?.passed ?? 0,
      failed: state.stats.byTask[task.id]?.failed ?? 0,
      recentAttempts: taskEvents.length,
      recentPassed: passed.length,
      recentFailed: failed,
      recentPassRate: passRate,
      distinctPassingSources,
      mastery: mastered ? 'mastered' : taskEvents.length < MIN_MASTERY_SAMPLES ? 'learning' : 'improving',
    };
  });
}

function weakest(rows) {
  return [...rows].sort((a, b) =>
    a.recentAttempts - b.recentAttempts ||
    a.recentPassRate - b.recentPassRate ||
    a.attempted - b.attempted ||
    a.id.localeCompare(b.id))[0];
}

export function examinerHolds(row) {
  return (row.recentAttempts ?? 0) >= 10 && (row.recentPassRate ?? 0) >= 1;
}

export function chooseTask(rows, scheduler = {}) {
  const selectionCount = Number.isSafeInteger(scheduler.selectionCount) ? scheduler.selectionCount : 0;
  const parked = new Set(scheduler.parkedTaskIds ?? []);
  for (const row of rows) {
    if (examinerHolds(row) || row.university) continue;
    if (row.qualityProfile && row.recentAttempts >= 10 && row.recentPassRate < 0.35) {
      parked.add(row.id);
    }
  }
  const masteredContracts = new Set();
  for (const row of rows) {
    if (row.university && examinerHolds(row)) {
      masteredContracts.add(row.id);
      if (row.baseTaskId) masteredContracts.add(row.baseTaskId);
    }
  }
  const eligible = rows.filter(row =>
    !parked.has(row.id) &&
    !examinerHolds(row) &&
    !masteredContracts.has(row.id));
  const universityLearning = eligible.filter(row => row.university);
  const qualityLearning = eligible.filter(row => row.qualityProfile);
  const legacyLearning = eligible.filter(row => !row.qualityProfile && !row.university);
  if (universityLearning.length) {
    return { selected: weakest(universityLearning), reason: 'university-growth' };
  }
  if (qualityLearning.length) {
    return { selected: weakest(qualityLearning), reason: 'quality-growth' };
  }
  if (legacyLearning.length) {
    return { selected: weakest(legacyLearning), reason: 'targeted-weakness' };
  }
  return { selected: null, reason: 'ladder-complete' };
}

export async function selectCurriculumTask(workDir, state, tasks) {
  const rows = classifyMastery(await recentEvents(workDir), state, tasks);
  const scheduler = state.scheduler ?? { selectionCount: 0, lastTaskId: null, lastReason: null };
  scheduler.parkedTaskIds = (scheduler.parkedTaskIds ?? []).filter(id => {
    const row = rows.find(item => item.id === id);
    if (row?.university && !examinerHolds(row)) return false;
    return true;
  });
  if (state.lastRun?.passed === true && state.lastRun.taskId) {
    scheduler.parkedTaskIds = scheduler.parkedTaskIds.filter(id => id !== state.lastRun.taskId);
  }
  if ((scheduler.failedBatchStreak ?? 0) >= 6 && scheduler.lastTaskId) {
    const stuck = rows.find(row => row.id === scheduler.lastTaskId);
    if (stuck && !examinerHolds(stuck) && stuck.recentPassed === 0) {
      if (!scheduler.parkedTaskIds.includes(stuck.id)) scheduler.parkedTaskIds.push(stuck.id);
    }
  }
  const choice = chooseTask(rows, scheduler);
  const repeatedFailedBatch = Boolean(choice.selected) &&
    choice.reason === 'university-growth' &&
    scheduler.lastTaskId === choice.selected.id &&
    state.lastRun?.taskId === choice.selected.id &&
    state.lastRun?.passed === false;
  scheduler.failedBatchStreak = repeatedFailedBatch ? (scheduler.failedBatchStreak ?? 0) + 1 : 0;
  scheduler.selectionCount++;
  scheduler.lastTaskId = choice.selected?.id ?? null;
  scheduler.lastReason = choice.reason;
  scheduler.updatedAt = new Date().toISOString();
  state.scheduler = scheduler;
  if (!choice.selected) return null;
  const task = tasks.find(candidate => candidate.id === choice.selected.id);
  if (!task || choice.reason !== 'university-growth') return task;
  const selectedTask = choice.selected.distinctPassingSources >= 2
    ? { ...task, revalidateLesson: true }
    : task;
  if (scheduler.failedBatchStreak < 1) {
    if (state.lastRun?.taskId !== choice.selected.id || state.lastRun?.passed !== true ||
        choice.selected.distinctPassingSources >= 2) return selectedTask;
    return {
      ...selectedTask,
      replanHint: 'The prior implementation passed. Produce a materially different solution that still satisfies the same contract: change the component composition and content structure rather than copying the retained source.',
    };
  }
  return {
    ...selectedTask,
    replanHint: UNIVERSITY_REPLAN_HINTS[(scheduler.failedBatchStreak - 1) % UNIVERSITY_REPLAN_HINTS.length],
  };
}

export async function masterySnapshot(workDir, state, tasks, events = null) {
  return classifyMastery(events ?? await recentEvents(workDir), state, tasks);
}
