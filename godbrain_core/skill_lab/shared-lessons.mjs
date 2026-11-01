import { createHash } from 'node:crypto';
import { promises as fs } from 'node:fs';
import path from 'node:path';
import { hashFiles, readJson, writeJson } from './gym-core.mjs';
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

async function sync(workDir, state, { restore, force, mongo }) {
  const file = path.join(workDir, 'shared-lessons-last.json');
  const previous = await readJson(file, null);
  const libraryDigest = digest(state.lessons ?? []);
  if (!restore && !force && previous?.ok === 1 && previous.libraryDigest === libraryDigest) return previous;
  try {
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
for (const record of records) {
  const id = record.lesson.runId + ':' + record.lesson.sourceHash;
  const stale = record.lesson.stale === true;
  db.qualified_lessons.updateOne(
    { _id: id, owner: ${JSON.stringify(OWNER)}, sourceHash: record.lesson.sourceHash,
      evaluatorVersion: record.lesson.evaluatorVersion },
    { $setOnInsert: { owner: ${JSON.stringify(OWNER)}, sourceHash: record.lesson.sourceHash,
        evaluatorVersion: record.lesson.evaluatorVersion, source: record.source, receipt: record.receipt,
        runId: record.lesson.runId, ...(!stale ? { stale: false } : {}) },
      $set: { lesson: record.lesson, ...(stale ? { stale: true } : {}) } },
    { upsert: true });
}
print(JSON.stringify({ ok: 1 }));
`);
    }
    if (restore) {
      const metadata = await mongo(LESSON_MONGO_DB, `
const items = db.qualified_lessons.find({ owner: ${JSON.stringify(OWNER)},
  evaluatorVersion: ${JSON.stringify(state.evaluatorVersion)} }, { _id: 1, runId: 1, stale: 1 }).toArray();
print(JSON.stringify({ ok: 1, items }));
`);
      const known = new Set((state.lessons ?? []).map(lesson => lesson.runId));
      const stale = new Set((metadata.items ?? []).filter(item => item.stale).map(item => item.runId));
      for (const lesson of state.lessons ?? []) if (stale.has(lesson.runId)) lesson.stale = true;
      const missing = (metadata.items ?? []).filter(item => !item.stale && !known.has(item.runId));
      for (let offset = 0; offset < missing.length; offset += 10) {
        const ids = missing.slice(offset, offset + 10).map(item => item._id);
        const result = await mongo(LESSON_MONGO_DB, `
print(JSON.stringify({ ok: 1, items: db.qualified_lessons.find({
  owner: ${JSON.stringify(OWNER)}, stale: false, _id: { $in: ${JSON.stringify(ids)} },
  evaluatorVersion: ${JSON.stringify(state.evaluatorVersion)} }).toArray() }));
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
    const counts = await mongo(LESSON_MONGO_DB, `
print(JSON.stringify({ ok: 1,
  stored: db.qualified_lessons.countDocuments({ owner: ${JSON.stringify(OWNER)} }),
  compatible: db.qualified_lessons.countDocuments({ owner: ${JSON.stringify(OWNER)}, stale: false,
    evaluatorVersion: ${JSON.stringify(state.evaluatorVersion)} }) }));
`);
    const receipt = {
      ok: 1, database: LESSON_MONGO_DB, at: new Date().toISOString(),
      stored: counts.stored, compatible: counts.compatible,
      libraryDigest: digest(state.lessons ?? []), modelIndependent: true,
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
