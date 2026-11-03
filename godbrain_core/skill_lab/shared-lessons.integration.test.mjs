import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { promises as fs } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import {
  assertBuilderMongoUri, BUILDER_MONGO_DB, checkBuilderDatabase, LESSON_MONGO_DB, runBuilderMongo,
} from './builder-db.mjs';
import { hashFiles, lessonSourceKey, writeJson } from './gym-core.mjs';
import { syncSharedLessons } from './shared-lessons.mjs';

const uri = process.env.GODBRAIN_SHARED_LESSONS_TEST_URI;
if (uri) {
  assertBuilderMongoUri(uri, LESSON_MONGO_DB);
  const parsed = new URL(uri);
  assert.equal(parsed.hostname, '127.0.0.1', 'Integration storage must be loopback-only.');
  assert.ok(parsed.port && parsed.port !== '27017', 'Use a disposable, non-production Mongo port.');
}

test('real Mongo preserves shared-source invalidations and immutable evidence across runs', {
  skip: !uri, timeout: 120_000,
}, async t => {
  const oldUri = process.env.GODBRAIN_SHARED_LESSONS_MONGO_URI;
  process.env.GODBRAIN_SHARED_LESSONS_MONGO_URI = uri;
  let workDir;
  let cleanup = async () => {};
  t.after(async () => {
    try {
      await cleanup();
    } finally {
      try {
        if (workDir) await fs.rm(workDir, { recursive: true, force: true });
      } finally {
        if (oldUri === undefined) delete process.env.GODBRAIN_SHARED_LESSONS_MONGO_URI;
        else process.env.GODBRAIN_SHARED_LESSONS_MONGO_URI = oldUri;
      }
    }
  });
  const empty = await runBuilderMongo(LESSON_MONGO_DB, `
print(JSON.stringify({ ok: 1, rows: db.qualified_lessons.countDocuments({}),
  invalidations: db.lesson_invalidations.countDocuments({}) }));
`);
  assert.equal(empty.rows, 0, 'Refusing to mutate a nonempty shared shelf.');
  assert.equal(empty.invalidations, 0, 'Refusing to mutate existing source invalidations.');
  const root = fileURLToPath(new URL('./work/tests/', import.meta.url));
  await fs.mkdir(root, { recursive: true });
  workDir = await fs.mkdtemp(path.join(root, 'shared-live-'));
  const suffix = randomUUID().replaceAll('-', '').slice(0, 12);
  const source = {
    'App.jsx': `export default function App(){return <main>Storage fixture ${suffix}</main>}`,
    'styles.css': 'body{margin:0}',
  };
  const sourceHash = hashFiles(source);
  const makeRecord = (sequence, taskId = `storage-${suffix}`, evaluatorVersion = 'storage-fixture-v1') => {
    const lesson = {
      runId: `${String(sequence).padStart(8, '0')}-${suffix}`,
      taskId, evaluatorVersion, sourceHash, family: 'integration', model: 'synthetic-fixture', stale: false,
    };
    return {
      lesson, source,
      receipt: {
        ...lesson, owner: 'godbrain-frontend-gym', scope: 'frontend-exercise-only',
        hostAuthority: false, passed: true,
        evidence: ['practice', 'transfer'].map((split, index) => ({
          split, seed: index + 1, taskId, passed: true,
          checks: [{ name: 'synthetic-storage-fixture', passed: true }], errors: [],
        })),
      },
    };
  };
  const older = makeRecord(1);
  const newer = makeRecord(2);
  const later = makeRecord(3);
  const otherTask = makeRecord(4, `other-${suffix}`);
  const otherEvaluator = makeRecord(5, older.lesson.taskId, 'storage-fixture-v2');
  const records = [older, newer, later, otherTask, otherEvaluator];
  const ids = records.map(item => `${item.lesson.runId}:${sourceHash}`);
  const keys = [...new Set(records.map(item => lessonSourceKey(item.lesson)))];
  cleanup = async () => {
    await runBuilderMongo(LESSON_MONGO_DB, `
db.qualified_lessons.deleteMany({ _id: { $in: ${JSON.stringify(ids)} } });
db.lesson_invalidations.deleteMany({ _id: { $in: ${JSON.stringify(keys)} } });
print(JSON.stringify({ ok: 1 }));
`);
  };
  for (const record of records) {
    const dir = path.join(workDir, 'runs', record.lesson.runId);
    await fs.mkdir(dir, { recursive: true });
    await writeJson(path.join(dir, 'source.json'), record.source);
    await writeJson(path.join(dir, 'receipt.json'), record.receipt);
  }
  const upload = record => syncSharedLessons(workDir, {
    lessons: [structuredClone(record.lesson)], evaluatorVersion: record.lesson.evaluatorVersion,
  }, { force: true });
  for (const record of [older, newer, otherTask, otherEvaluator]) {
    assert.equal((await upload(record)).ok, 1);
  }
  const readerDir = path.join(workDir, 'cached-reader');
  const readerState = { lessons: [], evaluatorVersion: older.lesson.evaluatorVersion };
  assert.equal((await syncSharedLessons(readerDir, readerState, { restore: true })).compatible, 3);
  newer.lesson.stale = true;
  assert.equal((await upload(newer)).ok, 1);
  const cachedFile = path.join(readerDir, 'shared-lessons-last.json');
  const cached = JSON.parse(await fs.readFile(cachedFile, 'utf8'));
  cached.at = new Date(Date.now() - 30_001).toISOString();
  await writeJson(cachedFile, cached);
  assert.equal((await syncSharedLessons(readerDir, readerState)).compatible, 1);
  assert.equal(readerState.lessons.find(item => item.runId === older.lesson.runId).stale, true);
  assert.equal(readerState.lessons.find(item => item.runId === newer.lesson.runId).stale, true);
  for (const record of [older, later]) assert.equal((await upload(record)).ok, 1);
  const stored = await runBuilderMongo(LESSON_MONGO_DB, `
print(JSON.stringify({ ok: 1, items: db.qualified_lessons.find({
  _id: { $in: ${JSON.stringify(ids)} } }).toArray() }));
`);
  assert.equal(stored.items.length, records.length);
  for (const record of [older, newer, later]) {
    const row = stored.items.find(item => item.runId === record.lesson.runId);
    assert.equal(row.stale, true);
    assert.equal(row.lesson.stale, true);
    assert.deepEqual(row.source, record.source);
    assert.deepEqual(row.receipt, record.receipt);
  }
  for (const [evaluatorVersion, expected] of [
    ['storage-fixture-v1', otherTask], ['storage-fixture-v2', otherEvaluator],
  ]) {
    const state = { lessons: [], evaluatorVersion };
    const result = await syncSharedLessons(path.join(workDir, evaluatorVersion), state, { restore: true });
    assert.equal(result.ok, 1);
    assert.equal(result.compatible, 1);
    assert.deepEqual(state.lessons.map(item => item.runId), [expected.lesson.runId]);
  }
  const oldBuilderUri = process.env.GODBRAIN_BUILDER_MONGO_URI;
  process.env.GODBRAIN_BUILDER_MONGO_URI = uri.replace(`/${LESSON_MONGO_DB}`, `/${BUILDER_MONGO_DB}`);
  let probe;
  try {
    probe = await checkBuilderDatabase();
    assert.deepEqual(probe.checks, ['insert', 'read', 'update', 'read']);
    assert.equal(probe.database, BUILDER_MONGO_DB);
  } finally {
    if (probe) {
      await runBuilderMongo(BUILDER_MONGO_DB, `
db.backend_checks.deleteOne({ _id: ${JSON.stringify(probe.probeId)}, owner: 'builder-round-trip-v1' });
print(JSON.stringify({ ok: 1 }));
`);
    }
    if (oldBuilderUri === undefined) delete process.env.GODBRAIN_BUILDER_MONGO_URI;
    else process.env.GODBRAIN_BUILDER_MONGO_URI = oldBuilderUri;
  }
});
