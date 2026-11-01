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
  let calls = 0;
  const matches = (row, filter) => Object.entries(filter).every(([key, value]) =>
    value && typeof value === 'object' && '$in' in value ? value.$in.includes(row[key]) : row[key] === value);
  return {
    rows,
    get calls() { return calls; },
    run: async (database, script) => {
      assert.equal(database, LESSON_MONGO_DB);
      calls++;
      let output;
      const collection = {
        updateOne(filter, update) {
          const existing = rows.get(filter._id);
          if (existing && !matches(existing, filter)) throw new Error('Immutable source conflict');
          rows.set(filter._id, { ...(existing ?? { _id: filter._id, ...update.$setOnInsert }), ...update.$set });
        },
        find(filter) { return { toArray: () => [...rows.values()].filter(row => matches(row, filter)) }; },
        countDocuments(filter) { return [...rows.values()].filter(row => matches(row, filter)).length; },
      };
      vm.runInNewContext(script, {
        db: { qualified_lessons: collection },
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
