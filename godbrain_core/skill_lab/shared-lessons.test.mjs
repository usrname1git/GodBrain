import assert from 'node:assert/strict';
import { promises as fs } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';
import test from 'node:test';
import { hashFiles, readJson, writeJson } from './gym-core.mjs';
import { GYM_MONGO_DB, assertGymMongoUri } from './gym-lab-db.mjs';
import { BUILDER_MONGO_DB, BuilderMongoError, LESSON_MONGO_DB, assertBuilderMongoUri } from './builder-db.mjs';
import { syncSharedLessons, validateSharedLesson } from './shared-lessons.mjs';

async function workspace(t) {
  const root = new URL('./work/tests/', import.meta.url);
  await fs.mkdir(root, { recursive: true });
  const dir = await fs.mkdtemp(path.join(fileURLToPath(root), 'shared-'));
  t.after(() => fs.rm(dir, { recursive: true, force: true }));
  return dir;
}

function record() {
  const source = { 'App.jsx': 'export default function App(){return <main>Saved</main>}', 'styles.css': 'body{margin:0}' };
  const lesson = {
    runId: '00000001-aaaaaaaaaaaa', taskId: 'trusted-v1', family: 'marketing-sites',
    sourceHash: hashFiles(source), evaluatorVersion: 'browser-test-v1', model: 'previous-model', stale: false,
  };
  const receipt = {
    ...lesson, owner: 'godbrain-frontend-gym', passed: true,
    evidence: ['practice', 'transfer'].map((split, index) => ({
      split, seed: index + 11, taskId: lesson.taskId, passed: true,
      checks: [{ name: 'synthetic-browser-check', passed: true }], errors: [],
    })),
    scope: 'frontend-exercise-only', hostAuthority: false,
  };
  return { lesson, source, receipt };
}

function fakeMongo() {
  const rows = new Map();
  const invalidations = new Map();
  let calls = 0;
  let uploads = 0;
  const valueAt = (row, key) => key.split('.').reduce((value, part) => value?.[part], row);
  const matches = (row, filter) => Object.entries(filter).every(([key, value]) =>
    value && typeof value === 'object' && '$in' in value
      ? value.$in.includes(valueAt(row, key)) : valueAt(row, key) === value);
  const collection = records => ({
    updateOne(filter, update) {
      const existing = records.get(filter._id);
      if (existing && !matches(existing, filter)) throw new Error('Immutable source conflict');
      records.set(filter._id, structuredClone({
        ...(existing ?? { _id: filter._id, ...update.$setOnInsert }), ...update.$set,
      }));
    },
    updateMany(filter, update) {
      for (const row of records.values()) {
        if (!matches(row, filter)) continue;
        for (const [key, value] of Object.entries(update.$set)) {
          const parts = key.split('.');
          const target = parts.slice(0, -1).reduce((item, part) => item[part], row);
          target[parts.at(-1)] = structuredClone(value);
        }
      }
    },
    findOne(filter) { return [...records.values()].find(row => matches(row, filter)) ?? null; },
    find(filter) {
      return { toArray: () => structuredClone([...records.values()].filter(row => matches(row, filter))) };
    },
    countDocuments(filter) { return [...records.values()].filter(row => matches(row, filter)).length; },
  });
  return {
    rows, invalidations,
    get calls() { return calls; },
    get uploads() { return uploads; },
    run: async (database, script) => {
      assert.equal(database, LESSON_MONGO_DB);
      calls++;
      if (script.includes('const records =')) uploads++;
      let output;
      vm.runInNewContext(script, {
        db: { qualified_lessons: collection(rows), lesson_invalidations: collection(invalidations) },
        print: value => { output = JSON.parse(value); },
      }, { timeout: 1000 });
      return output;
    },
  };
}

test('every Mongo shelf rejects Alexandria and the other shelves', () => {
  assert.throws(() => assertGymMongoUri(`mongodb://127.0.0.1:27017/${BUILDER_MONGO_DB}`), /never Alexandria/);
  assert.throws(() => assertGymMongoUri(`mongodb://127.0.0.1:27017/${LESSON_MONGO_DB}`), /never Alexandria/);
  for (const database of [BUILDER_MONGO_DB, LESSON_MONGO_DB]) {
    assert.equal(assertBuilderMongoUri(`mongodb://127.0.0.1:27017/${database}`, database).endsWith(database), true);
    for (const other of ['godbrain', 'admin', ...[GYM_MONGO_DB, BUILDER_MONGO_DB, LESSON_MONGO_DB].filter(x => x !== database)]) {
      assert.throws(() => assertBuilderMongoUri(`mongodb://127.0.0.1:27017/${other}`, database), /never Alexandria/);
    }
    assert.throws(() => assertBuilderMongoUri(`https://127.0.0.1/${database}`, database), /never Alexandria/);
  }
});

test('a later failure invalidates older and future runs of the exact source/task/evaluator', async t => {
  const from = await workspace(t);
  const mongo = fakeMongo();
  const older = record();
  const newer = structuredClone(older);
  newer.lesson.runId = newer.receipt.runId = '00000002-aaaaaaaaaaaa';
  const otherTask = structuredClone(older);
  otherTask.lesson.taskId = otherTask.receipt.taskId = 'another-task';
  otherTask.lesson.runId = otherTask.receipt.runId = '00000003-aaaaaaaaaaaa';
  for (const split of otherTask.receipt.evidence) split.taskId = otherTask.lesson.taskId;
  const otherEvaluator = structuredClone(older);
  otherEvaluator.lesson.evaluatorVersion = otherEvaluator.receipt.evaluatorVersion = 'browser-test-v2';
  otherEvaluator.lesson.runId = otherEvaluator.receipt.runId = '00000004-aaaaaaaaaaaa';
  const future = structuredClone(older);
  future.lesson.runId = future.receipt.runId = '00000005-aaaaaaaaaaaa';
  for (const item of [older, newer, otherTask, otherEvaluator, future]) {
    const dir = path.join(from, 'runs', item.lesson.runId);
    await fs.mkdir(dir, { recursive: true });
    await writeJson(path.join(dir, 'source.json'), item.source);
    await writeJson(path.join(dir, 'receipt.json'), item.receipt);
  }
  for (const item of [older, newer, otherTask, otherEvaluator]) {
    await syncSharedLessons(from, {
      lessons: [item.lesson], evaluatorVersion: item.lesson.evaluatorVersion,
    }, { force: true, mongo: mongo.run });
  }
  newer.lesson.stale = true;
  await syncSharedLessons(from, {
    lessons: [newer.lesson], evaluatorVersion: newer.lesson.evaluatorVersion,
  }, { force: true, mongo: mongo.run });
  assert.equal(mongo.invalidations.size, 1);
  for (const item of [older, future]) {
    await syncSharedLessons(from, {
      lessons: [structuredClone(item.lesson)], evaluatorVersion: item.lesson.evaluatorVersion,
    }, { force: true, mongo: mongo.run });
    assert.equal(mongo.rows.get(`${item.lesson.runId}:${item.lesson.sourceHash}`).stale, true);
  }
  for (const [version, expected] of [['browser-test-v1', otherTask], ['browser-test-v2', otherEvaluator]]) {
    const to = await workspace(t);
    const fresh = { lessons: [], evaluatorVersion: version };
    const result = await syncSharedLessons(to, fresh, { restore: true, mongo: mongo.run });
    assert.equal(result.compatible, 1);
    assert.deepEqual(fresh.lessons.map(item => item.runId), [expected.lesson.runId]);
  }
  const local = { lessons: [structuredClone(older.lesson)], evaluatorVersion: older.lesson.evaluatorVersion };
  await syncSharedLessons(from, local, { restore: true, mongo: mongo.run });
  assert.equal(local.lessons.find(item => item.runId === older.lesson.runId).stale, true);
});

test('legacy stale rows create durable source invalidations before restoration', async t => {
  const workDir = await workspace(t);
  const mongo = fakeMongo();
  const item = record();
  mongo.rows.set('legacy', { _id: 'legacy', owner: 'frontend-shared-lessons-v1',
    sourceHash: item.lesson.sourceHash, evaluatorVersion: item.lesson.evaluatorVersion,
    runId: item.lesson.runId, ...structuredClone(item), stale: true });
  const state = { lessons: [], evaluatorVersion: item.lesson.evaluatorVersion };
  const result = await syncSharedLessons(workDir, state, { restore: true, mongo: mongo.run });
  assert.equal(result.compatible, 0);
  assert.equal(mongo.invalidations.size, 1);
  assert.equal(state.lessonInvalidations.length, 1);
  assert.equal(state.lessons.length, 0);
});

test('unchanged readers refresh remote invalidations after the cache deadline without reuploading unchanged sources', async t => {
  const writer = await workspace(t), reader = await workspace(t);
  const mongo = fakeMongo(), item = record();
  const dir = path.join(writer, 'runs', item.lesson.runId);
  await fs.mkdir(dir, { recursive: true });
  await writeJson(path.join(dir, 'source.json'), item.source);
  await writeJson(path.join(dir, 'receipt.json'), item.receipt);
  await syncSharedLessons(writer, { lessons: [item.lesson], evaluatorVersion: item.lesson.evaluatorVersion }, { mongo: mongo.run });
  const state = { lessons: [], evaluatorVersion: item.lesson.evaluatorVersion };
  await syncSharedLessons(reader, state, { restore: true, mongo: mongo.run });
  const file = path.join(reader, 'shared-lessons-last.json');
  const expire = async () => {
    const receipt = await readJson(file);
    receipt.at = new Date(Date.now() - 30_001).toISOString();
    await writeJson(file, receipt);
  };
  await expire();
  const uploads = mongo.uploads, before = mongo.calls;
  await syncSharedLessons(reader, state, { mongo: mongo.run });
  assert.ok(mongo.calls > before);
  assert.equal(mongo.uploads, uploads);
  item.lesson.stale = true;
  await syncSharedLessons(writer, { lessons: [item.lesson], evaluatorVersion: item.lesson.evaluatorVersion }, { mongo: mongo.run });
  const cachedCalls = mongo.calls;
  await syncSharedLessons(reader, state, { mongo: mongo.run });
  assert.equal(mongo.calls, cachedCalls);
  await expire();
  const refreshed = await syncSharedLessons(reader, state, { mongo: mongo.run });
  assert.equal(refreshed.compatible, 0);
  assert.equal(state.lessons[0].stale, true);
  assert.equal(state.lessonInvalidations.length, 1);
});

test('expired unchanged readers surface database outages instead of returning cached success', async t => {
  const workDir = await workspace(t), mongo = fakeMongo();
  const state = { lessons: [], evaluatorVersion: 'browser-test-v1' };
  await syncSharedLessons(workDir, state, { mongo: mongo.run });
  const file = path.join(workDir, 'shared-lessons-last.json');
  const receipt = await readJson(file);
  receipt.at = new Date(Date.now() - 30_001).toISOString();
  await writeJson(file, receipt);
  const result = await syncSharedLessons(workDir, state, {
    mongo: async () => { throw new BuilderMongoError('Expired policy is unavailable.'); },
  });
  assert.equal(result.ok, 0);
  assert.match((await readJson(file)).error, /unavailable/);
});

test('missing, invalid or future cache timestamps cannot extend policy freshness', async t => {
  const workDir = await workspace(t), mongo = fakeMongo();
  const state = { lessons: [], evaluatorVersion: 'browser-test-v1' };
  await syncSharedLessons(workDir, state, { mongo: mongo.run });
  const file = path.join(workDir, 'shared-lessons-last.json');
  for (const at of [undefined, 'not-a-date', new Date(Date.now() + 60_000).toISOString()]) {
    const receipt = await readJson(file);
    receipt.at = at;
    await writeJson(file, receipt);
    const before = mongo.calls;
    assert.equal((await syncSharedLessons(workDir, state, { mongo: mongo.run })).ok, 1);
    assert.ok(mongo.calls > before);
  }
});

test('shared lessons require exact source, two passing fixtures and frontend-only authority', () => {
  const original = record();
  assert.doesNotThrow(() => validateSharedLesson(original));
  for (const change of [
    item => { item.source['styles.css'] = 'changed'; },
    item => { item.receipt.evidence[1].passed = false; },
    item => { item.receipt.hostAuthority = true; },
    item => { item.lesson.runId = '..\\escape'; },
    item => { item.receipt.evaluatorVersion = 'other'; },
    item => { item.receipt.evidence[1] = item.receipt.evidence[0]; },
    item => { item.receipt.evidence[1].checks[0].passed = false; },
  ]) {
    const item = structuredClone(original);
    change(item);
    assert.throws(() => validateSharedLesson(item), /Shared lesson/);
  }
});

test('a different model restores the shared source without repeating generation', async t => {
  const from = await workspace(t);
  const to = await workspace(t);
  const item = record();
  const runDir = path.join(from, 'runs', item.lesson.runId);
  await fs.mkdir(runDir, { recursive: true });
  await writeJson(path.join(runDir, 'source.json'), item.source);
  await writeJson(path.join(runDir, 'receipt.json'), item.receipt);
  const mongo = fakeMongo();
  const state = { lessons: [item.lesson], evaluatorVersion: item.lesson.evaluatorVersion };
  const result = await syncSharedLessons(from, state, { mongo: mongo.run });
  assert.equal(result.stored, 1);
  const calls = mongo.calls;
  await syncSharedLessons(from, state, { mongo: mongo.run });
  assert.equal(mongo.calls, calls);
  const otherModel = { lessons: [], evaluatorVersion: item.lesson.evaluatorVersion, model: 'new-model' };
  const restored = await syncSharedLessons(to, otherModel, { restore: true, mongo: mongo.run });
  assert.equal(restored.compatible, 1);
  assert.equal(otherModel.lessons[0].model, 'previous-model');
  assert.deepEqual(await readJson(path.join(to, 'runs', item.lesson.runId, 'source.json')), item.source);
  await fs.unlink(path.join(to, 'runs', item.lesson.runId, 'source.json'));
  await syncSharedLessons(to, otherModel, { restore: true, mongo: mongo.run });
  assert.deepEqual(await readJson(path.join(to, 'runs', item.lesson.runId, 'source.json')), item.source);
  state.lessons[0].stale = true;
  await syncSharedLessons(from, state, { mongo: mongo.run });
  assert.equal([...mongo.rows.values()][0].stale, true);
  state.lessons[0].stale = false;
  await syncSharedLessons(from, state, { force: true, mongo: mongo.run });
  assert.equal([...mongo.rows.values()][0].stale, true);
});

test('a shared database outage is an explicit pending receipt, never success', async t => {
  const workDir = await workspace(t);
  const result = await syncSharedLessons(workDir, { lessons: [], evaluatorVersion: 'test' }, {
    mongo: async () => { throw new BuilderMongoError('Test database unavailable.'); },
  });
  assert.equal(result.ok, 0);
  assert.match((await readJson(path.join(workDir, 'shared-lessons-last.json'))).error, /unavailable/);
});
