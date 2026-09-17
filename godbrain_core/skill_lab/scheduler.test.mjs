import assert from 'node:assert/strict';
import { promises as fs } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { chooseTask, classifyMastery, masterySnapshot, selectCurriculumTask } from './scheduler.mjs';

const tasks = [
  { id: 'legacy', title: 'Legacy', family: 'old' },
  { id: 'quality-a', title: 'Quality A', family: 'sites', qualityProfile: 'marketing-site-v1' },
  { id: 'quality-b', title: 'Quality B', family: 'sites', qualityProfile: 'marketing-site-v1' },
  {
    id: 'university-a',
    title: 'University A',
    family: 'university',
    qualityProfile: 'frontend-university-v1',
    university: { competencyId: 'component-composition', level: 1 },
  },
];

function state() {
  return {
    stats: {
      byTask: {
        legacy: { attempted: 600, passed: 590, failed: 10 },
        'quality-a': { attempted: 0, passed: 0, failed: 0 },
        'quality-b': { attempted: 0, passed: 0, failed: 0 },
        'university-a': { attempted: 40, passed: 36, failed: 4 },
      },
    },
  };
}

function passingEvents(taskId, count, sources = 2) {
  return Array.from({ length: count }, (_, index) => ({
    type: 'exercise_passed',
    taskId,
    sourceHash: `source-${index % sources}`,
  }));
}

test('mastery requires a strong rolling window and distinct passing sources', () => {
  const rows = classifyMastery([
    ...passingEvents('legacy', 20, 2),
    ...passingEvents('quality-a', 20, 1),
  ], state(), tasks);
  assert.equal(rows.find(row => row.id === 'legacy').mastery, 'mastered');
  assert.equal(rows.find(row => row.id === 'quality-a').mastery, 'improving');
  assert.equal(rows.find(row => row.id === 'quality-b').mastery, 'learning');
});

test('mastery ignores verdicts from obsolete evaluator epochs', () => {
  const obsolete = Array.from({ length: 40 }, () => ({
    type: 'attempt_failed',
    taskId: 'university-a',
  }));
  const current = passingEvents('university-a', 20, 2)
    .map(event => ({ ...event, evaluatorVersion: 'browser-v2' }));
  const row = classifyMastery([...obsolete, ...current], state(), tasks)
    .find(item => item.id === 'university-a');
  assert.equal(row.recentAttempts, 20);
  assert.equal(row.recentPassRate, 1);
  assert.equal(row.mastery, 'mastered');
});

test('persisted university mastery is not revoked by a short regression epoch', () => {
  const masteredTask = {
    ...tasks.find(item => item.id === 'university-a'),
    university: {
      ...tasks.find(item => item.id === 'university-a').university,
      status: 'mastered',
    },
  };
  const rows = classifyMastery([
    { type: 'exercise_passed', taskId: masteredTask.id, sourceHash: 'new-source', evaluatorVersion: 'browser-v2' },
  ], state(), [masteredTask]);
  assert.equal(rows[0].recentAttempts, 1);
  assert.equal(rows[0].mastery, 'mastered');
});

test('mastery history is retained per task despite heavy unrelated activity', async t => {
  const root = path.join(path.dirname(fileURLToPath(import.meta.url)), 'work', 'tests');
  await fs.mkdir(root, { recursive: true });
  const workDir = await fs.mkdtemp(path.join(root, 'scheduler-'));
  t.after(() => fs.rm(workDir, { recursive: true, force: true }));
  const events = [
    ...passingEvents('university-a', 20, 2),
    ...Array.from({ length: 2500 }, (_, index) => ({
      type: 'attempt_failed',
      taskId: `noise-${index % 4}`,
    })),
  ];
  await fs.writeFile(path.join(workDir, 'events.jsonl'), events.map(event => JSON.stringify(event)).join('\n'));
  const row = (await masterySnapshot(workDir, state(), tasks))
    .find(item => item.id === 'university-a');
  assert.equal(row.recentAttempts, 20);
  assert.equal(row.mastery, 'mastered');
});

test('new quality work outranks saturated legacy drills', () => {
  const rows = classifyMastery(passingEvents('legacy', 30, 3), state(), tasks);
  const choice = chooseTask(rows, { selectionCount: 1 });
  assert.equal(choice.reason, 'university-growth');
  assert.equal(choice.selected.id, 'university-a');
});

test('active university study outranks a weaker legacy quality course', () => {
  const events = [
    ...passingEvents('university-a', 36, 4),
    ...Array.from({ length: 4 }, () => ({ type: 'attempt_failed', taskId: 'university-a' })),
  ];
  const rows = classifyMastery(events, state(), tasks);
  const choice = chooseTask(rows, { selectionCount: 1 });
  assert.equal(rows.find(row => row.id === 'university-a').recentPassRate, 0.9);
  assert.equal(choice.reason, 'university-growth');
  assert.equal(choice.selected.id, 'university-a');
});

test('retargeted university courses ignore attempts from the previous exam', () => {
  const epoch = '2026-09-16T19:44:00.000Z';
  const tasksWithEpoch = tasks.map(task => task.id === 'university-a'
    ? { ...task, university: { ...task.university, retargetedAt: epoch, status: 'active' } }
    : task);
  const events = [
    { type: 'attempt_failed', taskId: 'university-a', at: '2026-09-16T08:00:00.000Z' },
    { type: 'attempt_failed', taskId: 'university-a', at: '2026-09-16T09:00:00.000Z' },
    { type: 'exercise_passed', taskId: 'university-a', at: '2026-09-16T20:00:00.000Z', sourceHash: 'a' },
    { type: 'attempt_failed', taskId: 'university-a', at: '2026-09-16T20:10:00.000Z' },
  ];
  const row = classifyMastery(events, state(), tasksWithEpoch).find(item => item.id === 'university-a');
  assert.equal(row.recentAttempts, 2);
  assert.equal(row.recentPassed, 1);
  assert.equal(row.recentFailed, 1);
});

test('parse failures count against quality mastery and a death spiral is parked', () => {
  const events = [
    ...passingEvents('university-a', 20, 2),
    ...passingEvents('quality-a', 3, 3),
    ...Array.from({ length: 9 }, () => ({ type: 'attempt_parse_failed', taskId: 'quality-a' })),
    ...passingEvents('quality-b', 2, 2),
  ];
  const rows = classifyMastery(events, state(), tasks);
  const a = rows.find(row => row.id === 'quality-a');
  assert.equal(a.recentAttempts, 12);
  assert.equal(a.recentPassed, 3);
  assert.ok(a.recentPassRate < 0.35);
  const choice = chooseTask(rows, { selectionCount: 4 });
  assert.notEqual(choice.selected.id, 'quality-a');
  assert.equal(choice.selected.id, 'quality-b');
});

test('zero-pass university growth is parked after a long fail streak', () => {
  const few = classifyMastery(
    Array.from({ length: 5 }, () => ({ type: 'attempt_failed', taskId: 'university-a' })),
    state(), tasks);
  const stillGrowing = chooseTask(few, { selectionCount: 3, lastTaskId: 'university-a', failedBatchStreak: 2 });
  assert.equal(stillGrowing.reason, 'university-growth');
  const many = classifyMastery(
    Array.from({ length: 20 }, () => ({ type: 'attempt_failed', taskId: 'university-a' })),
    state(), tasks);
  const parked = chooseTask(many, { selectionCount: 3, lastTaskId: 'university-a', failedBatchStreak: 8 });
  assert.notEqual(parked.selected.id, 'university-a');
  assert.notEqual(parked.reason, 'university-growth');
  const maintenance = chooseTask(many, { selectionCount: 1, parkedTaskIds: ['university-a'] });
  assert.notEqual(maintenance.selected.id, 'university-a');
});

test('mastered drills are sampled as regression rather than repeated continuously', () => {
  const events = tasks.flatMap(task => passingEvents(task.id, 24, 3));
  const rows = classifyMastery(events, state(), tasks);
  const regression = chooseTask(rows, { selectionCount: 20 });
  assert.equal(regression.reason, 'regression');
  const maintenance = chooseTask(rows, { selectionCount: 21 });
  assert.equal(maintenance.reason, 'quality-maintenance');
  assert.equal(maintenance.selected.qualityProfile, 'marketing-site-v1');
});

test('repeated failed university batches rotate autonomous replans', async t => {
  const root = path.join(path.dirname(fileURLToPath(import.meta.url)), 'work', 'tests');
  await fs.mkdir(root, { recursive: true });
  const workDir = await fs.mkdtemp(path.join(root, 'scheduler-'));
  t.after(() => fs.rm(workDir, { recursive: true, force: true }));
  const current = state();
  current.lastRun = { taskId: 'university-a', passed: false };
  current.scheduler = {
    selectionCount: 1,
    lastTaskId: 'university-a',
    lastReason: 'university-growth',
    failedBatchStreak: 0,
  };
  const first = await selectCurriculumTask(workDir, current, tasks);
  assert.match(first.replanHint, /typed prop contract/);
  const second = await selectCurriculumTask(workDir, current, tasks);
  assert.match(second.replanHint, /minimal semantic shell/);
});

test('a passing university batch requests a distinct implementation for mastery evidence', async t => {
  const root = path.join(path.dirname(fileURLToPath(import.meta.url)), 'work', 'tests');
  await fs.mkdir(root, { recursive: true });
  const workDir = await fs.mkdtemp(path.join(root, 'scheduler-'));
  t.after(() => fs.rm(workDir, { recursive: true, force: true }));
  const current = state();
  current.lastRun = { taskId: 'university-a', passed: true };
  current.scheduler = {
    selectionCount: 1,
    lastTaskId: 'university-a',
    lastReason: 'university-growth',
    failedBatchStreak: 2,
  };
  const selected = await selectCurriculumTask(workDir, current, tasks);
  assert.equal(current.scheduler.failedBatchStreak, 0);
  assert.match(selected.replanHint, /materially different solution/);
});

test('university stops forcing variation after two passing source hashes', async t => {
  const root = path.join(path.dirname(fileURLToPath(import.meta.url)), 'work', 'tests');
  await fs.mkdir(root, { recursive: true });
  const workDir = await fs.mkdtemp(path.join(root, 'scheduler-'));
  t.after(() => fs.rm(workDir, { recursive: true, force: true }));
  await fs.writeFile(path.join(workDir, 'events.jsonl'), [
    JSON.stringify({ type: 'exercise_passed', taskId: 'university-a', sourceHash: 'source-a' }),
    JSON.stringify({ type: 'exercise_passed', taskId: 'university-a', sourceHash: 'source-b' }),
  ].join('\n'));
  const current = state();
  current.lastRun = { taskId: 'university-a', passed: true };
  current.scheduler = {
    selectionCount: 1,
    lastTaskId: 'university-a',
    lastReason: 'university-growth',
    failedBatchStreak: 0,
  };
  const selected = await selectCurriculumTask(workDir, current, tasks);
  assert.equal(selected.replanHint, undefined);
  assert.equal(selected.revalidateLesson, true);
});
