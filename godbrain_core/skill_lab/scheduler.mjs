import { promises as fs } from 'node:fs';
import path from 'node:path';

const WINDOW = 40;
const MIN_MASTERY_SAMPLES = 20;
const MASTERY_RATE = 0.95;
const REGRESSION_INTERVAL = 20;
const LEGACY_WEAK_INTERVAL = 5;
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
    const latestEvaluatorVersion = [...allTaskEvents].reverse()
      .find(event => typeof event.evaluatorVersion === 'string' && event.evaluatorVersion)?.evaluatorVersion;
    const currentEvents = latestEvaluatorVersion
      ? allTaskEvents.filter(event => event.evaluatorVersion === latestEvaluatorVersion)
      : allTaskEvents;
    const taskEvents = currentEvents.slice(-WINDOW);
    const passed = taskEvents.filter(event => event.type === 'exercise_passed');
    const passRate = taskEvents.length ? passed.length / taskEvents.length : 0;
    const distinctPassingSources = new Set(passed.map(event => event.sourceHash).filter(Boolean)).size;
    const measuredMastery = taskEvents.length >= MIN_MASTERY_SAMPLES &&
      passRate >= MASTERY_RATE && distinctPassingSources >= 2;
    const mastered = task.university?.status === 'mastered' || measuredMastery;
    return {
      id: task.id,
      title: task.title,
      family: task.family,
      qualityProfile: task.qualityProfile ?? null,
      university: task.university ?? null,
      attempted: state.stats.byTask[task.id]?.attempted ?? 0,
      passed: state.stats.byTask[task.id]?.passed ?? 0,
      failed: state.stats.byTask[task.id]?.failed ?? 0,
      recentAttempts: taskEvents.length,
      recentPassed: passed.length,
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

export function chooseTask(rows, scheduler = {}) {
  const selectionCount = Number.isSafeInteger(scheduler.selectionCount) ? scheduler.selectionCount : 0;
  const parked = new Set(scheduler.parkedTaskIds ?? []);
  for (const row of rows) {
    if (row.university && row.mastery !== 'mastered' &&
        row.recentAttempts >= MIN_MASTERY_SAMPLES && row.recentPassed === 0) {
      parked.add(row.id);
    }
    if (row.qualityProfile && !row.university && row.mastery !== 'mastered' &&
        row.recentAttempts >= 10 && row.recentPassRate < 0.35) {
      parked.add(row.id);
    }
  }
  const allQuality = rows.filter(row => row.qualityProfile);
  const quality = allQuality.filter(row => !parked.has(row.id));
  const universityLearning = quality.filter(row => row.university && row.mastery !== 'mastered');
  const qualityLearning = quality.filter(row => row.mastery !== 'mastered');
  const legacyLearning = rows.filter(row => !row.qualityProfile && row.mastery !== 'mastered');
  const mastered = rows.filter(row => row.mastery === 'mastered');
  let selected;
  let reason;
  if (universityLearning.length) {
    selected = weakest(universityLearning);
    reason = 'university-growth';
  } else if (qualityLearning.length) {
    selected = weakest(qualityLearning);
    reason = 'quality-growth';
  } else if (mastered.length && selectionCount % REGRESSION_INTERVAL === 0) {
    selected = mastered[selectionCount % mastered.length];
    reason = 'regression';
  } else if (legacyLearning.length && selectionCount % LEGACY_WEAK_INTERVAL === 0) {
    selected = weakest(legacyLearning);
    reason = 'targeted-weakness';
  } else if (quality.length) {
    selected = quality[selectionCount % quality.length];
    reason = 'quality-maintenance';
  } else {
    selected = weakest(legacyLearning.length ? legacyLearning : rows);
    reason = legacyLearning.length ? 'targeted-weakness' : 'regression';
  }
  return { selected, reason };
}

export async function selectCurriculumTask(workDir, state, tasks) {
  const rows = classifyMastery(await recentEvents(workDir), state, tasks);
  const scheduler = state.scheduler ?? { selectionCount: 0, lastTaskId: null, lastReason: null };
  scheduler.parkedTaskIds = [...(scheduler.parkedTaskIds ?? [])];
  if (state.lastRun?.passed === true && state.lastRun.taskId) {
    scheduler.parkedTaskIds = scheduler.parkedTaskIds.filter(id => id !== state.lastRun.taskId);
  }
  if ((scheduler.failedBatchStreak ?? 0) >= 6 && scheduler.lastTaskId) {
    const stuck = rows.find(row => row.id === scheduler.lastTaskId);
    if (stuck && stuck.mastery !== 'mastered' && stuck.recentPassed === 0) {
      if (!scheduler.parkedTaskIds.includes(stuck.id)) scheduler.parkedTaskIds.push(stuck.id);
    }
  }
  const choice = chooseTask(rows, scheduler);
  const repeatedFailedBatch = choice.reason === 'university-growth' &&
    scheduler.lastTaskId === choice.selected.id &&
    state.lastRun?.taskId === choice.selected.id &&
    state.lastRun?.passed === false;
  scheduler.failedBatchStreak = repeatedFailedBatch ? (scheduler.failedBatchStreak ?? 0) + 1 : 0;
  scheduler.selectionCount++;
  scheduler.lastTaskId = choice.selected.id;
  scheduler.lastReason = choice.reason;
  scheduler.updatedAt = new Date().toISOString();
  state.scheduler = scheduler;
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
