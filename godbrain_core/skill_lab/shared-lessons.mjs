import { createHash } from 'node:crypto';
import { promises as fs } from 'node:fs';
import path from 'node:path';
import { hashFiles, invalidateLessonSource, lessonSourceKey, readJson, writeJson } from './gym-core.mjs';
import { BuilderMongoError, LESSON_MONGO_DB, runBuilderMongo } from './builder-db.mjs';

const OWNER = 'frontend-shared-lessons-v1';
const RUN_ID = /^\d{8}-[a-f0-9]{12}$/;
const digest = value => createHash('sha256').update(JSON.stringify(value)).digest('hex');
let syncTail = Promise.resolve();

export function validateSharedLesson(record) {
  const { lesson, source, receipt } = record ?? {};
  if (!lesson || !RUN_ID.test(lesson.runId) || !source || !receipt ||
      hashFiles(source) !== lesson.sourceHash || receipt.sourceHash !== lesson.sourceHash ||
      receipt.runId !== lesson.runId || receipt.evaluatorVersion !== lesson.evaluatorVersion ||
      receipt.taskId !== lesson.taskId || receipt.passed !== true ||
      receipt.owner !== 'godbrain-frontend-gym' ||
      receipt.scope !== 'frontend-exercise-only' || receipt.hostAuthority !== false ||
      !Array.isArray(receipt.evidence) || receipt.evidence.length !== 2 ||
      new Set(receipt.evidence.map(split => split.seed)).size !== 2 ||
      !receipt.evidence.every((split, index) =>
        split.passed === true && split.split === ['practice', 'transfer'][index] &&
        split.taskId === lesson.taskId && Number.isSafeInteger(split.seed) &&
        Array.isArray(split.checks) && split.checks.length > 0 && split.checks.every(check => check.passed === true) &&
        Array.isArray(split.errors) && split.errors.length === 0)) {
    throw new Error('Shared lesson lacks matching source and two passing browser receipts.');
  }
}

export function syncSharedLessons(workDir, state, { restore = false, force = false, mongo = runBuilderMongo } = {}) {
  const action = syncTail.then(() => sync(workDir, state, { restore, force, mongo }));
  syncTail = action.catch(() => {});
  return action;
}

async function restoreSource(workDir, record) {
  validateSharedLesson(record);
  const runDir = path.join(workDir, 'runs', record.lesson.runId);
  await fs.mkdir(runDir, { recursive: true });
  for (const [name, value] of [['source.json', record.source], ['receipt.json', record.receipt]]) {
    const target = path.join(runDir, name);
    const existing = await readJson(target, null);
    if (existing && JSON.stringify(existing) !== JSON.stringify(value)) {
      throw new Error('Shared restore conflicts with immutable local evidence.');
    }
    if (!existing) await fs.writeFile(target, `${JSON.stringify(value, null, 2)}\n`, { flag: 'wx' });
  }
}

function applyInvalidations(state, invalidations) {
  state.lessonInvalidations ??= [];
  for (const item of invalidations) invalidateLessonSource(state, item);
  const blocked = new Set(state.lessonInvalidations.map(lessonSourceKey));
  for (const lesson of state.lessons ?? []) if (blocked.has(lessonSourceKey(lesson))) lesson.stale = true;
}

function libraryDigest(state) {
  return digest({ lessons: state.lessons ?? [], invalidations: state.lessonInvalidations });
}

async function sync(workDir, state, { restore, force, mongo }) {
  const file = path.join(workDir, 'shared-lessons-last.json');
  const previous = await readJson(file, null);
  applyInvalidations(state, (state.lessons ?? []).filter(lesson => lesson.stale));
  if (!restore && !force && previous?.ok === 1 && previous.libraryDigest === libraryDigest(state)) return previous;
  try {
    const policy = await mongo(LESSON_MONGO_DB, `
const owner = ${JSON.stringify(OWNER)};
const sourceKey = ${lessonSourceKey.toString()};
const invalidations = ${JSON.stringify(state.lessonInvalidations)};
for (const row of db.qualified_lessons.find({ owner, stale: true }).toArray()) {
  invalidations.push(row.lesson);
}
for (const { taskId, sourceHash, evaluatorVersion } of invalidations) {
  db.lesson_invalidations.updateOne(
    { _id: sourceKey({ taskId, sourceHash, evaluatorVersion }), owner },
    { $setOnInsert: { owner, taskId, sourceHash, evaluatorVersion } }, { upsert: true });
}
print(JSON.stringify({ ok: 1, items: db.lesson_invalidations.find({ owner }).toArray() }));
`);
    applyInvalidations(state, policy.items ?? []);
    const records = [];
    const entries = Object.fromEntries((state.lessons ?? []).map(lesson => [lesson.runId, digest(lesson)]));
    for (const lesson of state.lessons ?? []) {
      if (!force && !restore && previous?.entries?.[lesson.runId] === entries[lesson.runId]) continue;
      if (!RUN_ID.test(lesson.runId)) throw new Error('Invalid shared lesson run ID.');
      const runDir = path.join(workDir, 'runs', lesson.runId);
      let record = {
        lesson, source: await readJson(path.join(runDir, 'source.json'), null),
        receipt: await readJson(path.join(runDir, 'receipt.json'), null),
      };
      if (restore && (!record.source || !record.receipt)) {
        const result = await mongo(LESSON_MONGO_DB, `
print(JSON.stringify({ ok: 1, items: db.qualified_lessons.find({
  owner: ${JSON.stringify(OWNER)}, _id: ${JSON.stringify(`${lesson.runId}:${lesson.sourceHash}`)},
  evaluatorVersion: ${JSON.stringify(lesson.evaluatorVersion)} }).toArray() }));
`);
        record = result.items?.[0];
        if (!record || record.lesson.runId !== lesson.runId || record.lesson.sourceHash !== lesson.sourceHash) {
          throw new Error('Missing local lesson has no matching shared backup.');
        }
        await restoreSource(workDir, record);
        record = { ...record, lesson };
      }
      validateSharedLesson(record);
      records.push(record);
    }
    for (let offset = 0; offset < records.length; offset += 25) {
      const batch = records.slice(offset, offset + 25);
      await mongo(LESSON_MONGO_DB, `
const records = ${JSON.stringify(batch)};
const sourceKey = ${lessonSourceKey.toString()};
for (const record of records) {
  const id = record.lesson.runId + ':' + record.lesson.sourceHash;
  const stale = record.lesson.stale === true || Boolean(db.lesson_invalidations.findOne({
    _id: sourceKey(record.lesson), owner: ${JSON.stringify(OWNER)} }));
  db.qualified_lessons.updateOne(
    { _id: id, owner: ${JSON.stringify(OWNER)}, sourceHash: record.lesson.sourceHash,
      evaluatorVersion: record.lesson.evaluatorVersion },
    { $setOnInsert: { owner: ${JSON.stringify(OWNER)}, sourceHash: record.lesson.sourceHash,
        evaluatorVersion: record.lesson.evaluatorVersion, source: record.source, receipt: record.receipt,
        runId: record.lesson.runId, ...(!stale ? { stale: false } : {}) },
      $set: { lesson: { ...record.lesson, stale }, ...(stale ? { stale: true } : {}) } },
    { upsert: true });
}
print(JSON.stringify({ ok: 1 }));
`);
    }
    const metadata = await mongo(LESSON_MONGO_DB, `
const owner = ${JSON.stringify(OWNER)};
const sourceKey = ${lessonSourceKey.toString()};
const invalidations = db.lesson_invalidations.find({ owner }).toArray();
for (const item of invalidations) {
  db.qualified_lessons.updateMany({ owner, 'lesson.taskId': item.taskId,
    sourceHash: item.sourceHash, evaluatorVersion: item.evaluatorVersion },
    { $set: { stale: true, 'lesson.stale': true } });
}
const blocked = new Set(invalidations.map(sourceKey));
const items = db.qualified_lessons.find({ owner,
  evaluatorVersion: ${JSON.stringify(state.evaluatorVersion)} },
  { _id: 1, runId: 1, stale: 1, 'lesson.taskId': 1,
    'lesson.sourceHash': 1, 'lesson.evaluatorVersion': 1 }).toArray()
  .map(row => ({ _id: row._id, runId: row.runId, stale: row.stale || blocked.has(sourceKey(row.lesson)) }));
print(JSON.stringify({ ok: 1, items, invalidations,
  stored: db.qualified_lessons.countDocuments({ owner }),
  compatible: items.filter(item => !item.stale).length }));
`);
    applyInvalidations(state, metadata.invalidations ?? []);
    const stale = new Set((metadata.items ?? []).filter(item => item.stale).map(item => item.runId));
    for (const lesson of state.lessons ?? []) if (stale.has(lesson.runId)) lesson.stale = true;
    if (restore) {
      const known = new Set((state.lessons ?? []).map(lesson => lesson.runId));
      const missing = (metadata.items ?? []).filter(item => !item.stale && !known.has(item.runId));
      for (let offset = 0; offset < missing.length; offset += 10) {
        const ids = missing.slice(offset, offset + 10).map(item => item._id);
        const result = await mongo(LESSON_MONGO_DB, `
const sourceKey = ${lessonSourceKey.toString()};
const blocked = new Set(db.lesson_invalidations.find({ owner: ${JSON.stringify(OWNER)} })
  .toArray().map(sourceKey));
print(JSON.stringify({ ok: 1, items: db.qualified_lessons.find({
  owner: ${JSON.stringify(OWNER)}, stale: false, _id: { $in: ${JSON.stringify(ids)} },
  evaluatorVersion: ${JSON.stringify(state.evaluatorVersion)} }).toArray()
  .filter(row => !blocked.has(sourceKey(row.lesson))) }));
`);
        for (const record of result.items ?? []) {
          validateSharedLesson(record);
          if (record.lesson.stale || record.lesson.evaluatorVersion !== state.evaluatorVersion) {
            throw new Error('Shared shelf returned an incompatible lesson.');
          }
          await restoreSource(workDir, record);
          state.lessons.push(record.lesson);
        }
      }
    }
    const receipt = {
      ok: 1, database: LESSON_MONGO_DB, at: new Date().toISOString(),
      stored: metadata.stored, compatible: metadata.compatible,
      libraryDigest: libraryDigest(state), modelIndependent: true,
      entries: Object.fromEntries((state.lessons ?? []).map(lesson => [lesson.runId, digest(lesson)])),
    };
    await writeJson(file, receipt);
    return receipt;
  } catch (error) {
    if (!(error instanceof BuilderMongoError)) throw error;
    const receipt = { ok: 0, database: LESSON_MONGO_DB, at: new Date().toISOString(), error: error.message };
    await writeJson(file, receipt);
    console.error(`Shared lesson sync pending: ${error.message}`);
    return receipt;
  }
}
