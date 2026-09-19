import assert from 'node:assert/strict';
import { promises as fs } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { chooseTask, classifyMastery, examinerHolds, masterySnapshot, selectCurriculumTask } from './scheduler.mjs';

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

test('evaluator family keeps a contrast collapse across hash bumps', () => {
  const masteredTask = {
    ...tasks.find(item => item.id === 'university-a'),
    university: {
      ...tasks.find(item => item.id === 'university-a').university,
      status: 'mastered',
    },
  };
  const events = [
    ...Array.from({ length: 20 }, () => ({
      type: 'attempt_failed',
      taskId: masteredTask.id,
      evaluatorVersion: 'browser-evaluator-v6:aaa',
    })),
    ...Array.from({ length: 8 }, () => ({
      type: 'attempt_failed',
      taskId: masteredTask.id,
      evaluatorVersion: 'browser-evaluator-v6:bbb',
    })),
  ];
  const row = classifyMastery(events, state(), [masteredTask])[0];
  assert.equal(row.recentAttempts, 28);
  assert.equal(row.recentPassed, 0);
  assert.equal(row.mastery, 'improving');
});

test('persisted university mastery collapses when the current examiner fails the window', () => {
  const masteredTask = {
    ...tasks.find(item => item.id === 'university-a'),
    university: {
      ...tasks.find(item => item.id === 'university-a').university,
      status: 'mastered',
    },
  };
  const events = Array.from({ length: 20 }, () => ({
    type: 'attempt_failed',
    taskId: masteredTask.id,
    evaluatorVersion: 'browser-v6',
  }));
  const rows = classifyMastery(events, state(), [
    ...tasks.filter(item => item.id !== masteredTask.id),
    masteredTask,
  ]);
  assert.equal(rows.find(item => item.id === masteredTask.id).mastery, 'improving');
  assert.equal(rows.find(item => item.id === masteredTask.id).recentPassed, 0);
  const choice = chooseTask(rows, { selectionCount: 1 });
  assert.equal(choice.reason, 'university-growth');
  assert.equal(choice.selected.id, masteredTask.id);
});

test('ledger-mastered cycle 1 courses still retrain when contrast is 0%', () => {
  const layout = {
    id: 'university-responsive-layout-v1',
    title: 'Layout',
    family: 'university',
    qualityProfile: 'frontend-university-v1',
    baseTaskId: 'quality-a',
    university: { competencyId: 'responsive-layout', level: 2, cycle: 1, stage: 1, status: 'mastered' },
  };
  const events = Array.from({ length: 20 }, () => ({
    type: 'attempt_failed', taskId: layout.id, evaluatorVersion: 'browser-evaluator-v6:x',
  }));
  const rows = classifyMastery(events, state(), [
    ...tasks.filter(item => item.id !== 'university-a'),
    layout,
  ]);
  assert.equal(examinerHolds(rows.find(item => item.id === layout.id)), false);
  const choice = chooseTask(rows, { selectionCount: 1 });
  assert.equal(choice.selected.id, layout.id);
});

test('cycle 4 visual God still retrains when the current examiner collapses', () => {
  const visual = {
    id: 'university-visual-god-v1',
    title: 'Visual God',
    family: 'university',
    qualityProfile: 'frontend-university-v1',
    baseTaskId: 'visual-god-v1',
    university: { competencyId: 'visual-god', level: 9, cycle: 4, stage: 1, status: 'mastered' },
  };
  const events = Array.from({ length: 20 }, () => ({
    type: 'attempt_failed', taskId: visual.id, evaluatorVersion: 'browser-evaluator-v6:x',
  }));
  const rows = classifyMastery(events, state(), [
    ...tasks.filter(item => item.id !== 'university-a'),
    visual,
  ]);
  assert.equal(examinerHolds(rows.find(item => item.id === visual.id)), false);
  const choice = chooseTask(rows, { selectionCount: 1 });
  assert.equal(choice.selected.id, visual.id);
});

test('a majority-passing window is still retrained until it is 100%', () => {
  const masteredTask = {
    ...tasks.find(item => item.id === 'university-a'),
    university: {
      ...tasks.find(item => item.id === 'university-a').university,
      status: 'mastered',
    },
  };
  const events = [
    ...passingEvents(masteredTask.id, 6, 2),
    ...Array.from({ length: 4 }, () => ({ type: 'attempt_failed', taskId: masteredTask.id })),
    ...passingEvents('quality-b', 24, 3),
    ...passingEvents('legacy', 24, 3),
  ];
  const rows = classifyMastery(events, state(), [
    ...tasks.filter(item => item.id !== 'university-a'),
    masteredTask,
  ]);
  assert.equal(examinerHolds(rows.find(item => item.id === masteredTask.id)), false);
  const choice = chooseTask(rows, { selectionCount: 1 });
  assert.equal(choice.selected.id, masteredTask.id);
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
  assert.equal(examinerHolds(rows.find(row => row.id === 'university-a')), false);
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

test('zero-pass university exam is persisted on parkedTaskIds', async t => {
  const root = path.join(path.dirname(fileURLToPath(import.meta.url)), 'work', 'tests');
  await fs.mkdir(root, { recursive: true });
  const workDir = await fs.mkdtemp(path.join(root, 'scheduler-'));
  t.after(() => fs.rm(workDir, { recursive: true, force: true }));
  await fs.writeFile(
    path.join(workDir, 'events.jsonl'),
    Array.from({ length: 20 }, () => JSON.stringify({ type: 'attempt_failed', taskId: 'university-a' })).join('\n'),
  );
  const current = state();
  current.scheduler = { selectionCount: 1, parkedTaskIds: ['university-a'] };
  const selected = await selectCurriculumTask(workDir, current, tasks);
  assert.equal(selected.id, 'university-a');
  assert.equal(current.scheduler.parkedTaskIds.includes('university-a'), false);
  assert.equal(examinerHolds(classifyMastery(
    Array.from({ length: 20 }, () => ({ type: 'attempt_failed', taskId: 'university-a' })),
    state(), tasks,
  ).find(item => item.id === 'university-a')), false);
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
  const retrains = chooseTask(many, { selectionCount: 3, lastTaskId: 'university-a', failedBatchStreak: 8 });
  assert.equal(retrains.reason, 'university-growth');
  assert.equal(retrains.selected.id, 'university-a');
});

test('mastered university courses and their contracts are never replayed', () => {
  const universityMastered = {
    id: 'university-nav-v1',
    title: 'University nav',
    family: 'university',
    qualityProfile: 'frontend-university-v1',
    baseTaskId: 'quality-a',
    university: { competencyId: 'accessible-navigation', level: 2, status: 'mastered' },
  };
  const events = [
    ...passingEvents('university-nav-v1', 24, 3),
    ...passingEvents('quality-a', 24, 3),
    ...passingEvents('quality-b', 24, 3),
    ...passingEvents('legacy', 24, 3),
  ];
  const rows = classifyMastery(events, state(), [
    ...tasks.filter(item => item.id !== 'university-a'),
    universityMastered,
  ]);
  const idle = chooseTask(rows, { selectionCount: 20 });
  assert.equal(idle.reason, 'ladder-complete');
  assert.equal(idle.selected, null);
});

test('ledger-mastered university still hides the base contract after a contrast collapse', () => {
  const collapsed = {
    id: 'university-tokens-v1',
    title: 'Tokens',
    family: 'university',
    qualityProfile: 'frontend-university-v1',
    baseTaskId: 'quality-a',
    university: { competencyId: 'design-tokens', level: 2, status: 'mastered' },
  };
  const events = [
    ...Array.from({ length: 20 }, () => ({ type: 'attempt_failed', taskId: 'university-tokens-v1', evaluatorVersion: 'browser-evaluator-v6:x' })),
    ...passingEvents('quality-b', 24, 3),
    ...passingEvents('legacy', 24, 3),
  ];
  const rows = classifyMastery(events, state(), [
    ...tasks.filter(item => item.id !== 'university-a'),
    collapsed,
  ]);
  const retrains = chooseTask(rows, { selectionCount: 3 });
  assert.equal(retrains.reason, 'university-growth');
  assert.equal(retrains.selected.id, 'university-tokens-v1');
});

test('unmastered university work still outranks a mastered contract replay', () => {
  const universityActive = {
    id: 'university-shop-v1',
    title: 'Shop',
    family: 'university',
    qualityProfile: 'frontend-university-v1',
    baseTaskId: 'shop-cart-checkout-v1',
    university: { competencyId: 'shop-cart-checkout', level: 9, status: 'active' },
  };
  const events = [
    ...passingEvents('quality-a', 24, 3),
    ...passingEvents('legacy', 24, 3),
  ];
  const rows = classifyMastery(events, state(), [...tasks, universityActive]);
  const choice = chooseTask(rows, { selectionCount: 1 });
  assert.equal(choice.reason, 'university-growth');
  assert.equal(choice.selected.id, 'university-shop-v1');
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
