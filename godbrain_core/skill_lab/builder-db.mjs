import { execFile } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { promisify } from 'node:util';
import { resolveMongosh } from './gym-lab-db.mjs';

const execute = promisify(execFile);
export const BUILDER_MONGO_DB = 'godbrain_builder_test';
export const LESSON_MONGO_DB = 'godbrain_gym_memory';
export class BuilderMongoError extends Error {}

export function assertBuilderMongoUri(uri, database) {
  if (![BUILDER_MONGO_DB, LESSON_MONGO_DB].includes(database)) {
    throw new Error('Unsupported builder database.');
  }
  if (typeof uri !== 'string' || !uri.trim()) throw new Error('Builder Mongo URI is missing.');
  let dbName = '';
  try {
    dbName = new URL(uri.replace(/^mongodb(\+srv)?:/i, 'http:')).pathname.replace(/^\//, '').split('/')[0];
  } catch {
    throw new Error('Builder Mongo URI is invalid.');
  }
  if (!/^mongodb(?:\+srv)?:\/\//i.test(uri) || dbName !== database) {
    throw new Error(`Builder must use database ${database}, never Alexandria godbrain. Got ${dbName || 'none'}.`);
  }
  return uri;
}

export async function runBuilderMongo(database, script) {
  const variable = database === BUILDER_MONGO_DB ? 'GODBRAIN_BUILDER_MONGO_URI' : 'GODBRAIN_SHARED_LESSONS_MONGO_URI';
  const uri = assertBuilderMongoUri(process.env[variable] || `mongodb://127.0.0.1:27017/${database}`, database);
  const file = path.join(os.tmpdir(), `godbrain-builder-${process.pid}-${randomUUID()}.js`);
  await fs.writeFile(file, `
if (db.getName() !== ${JSON.stringify(database)}) throw new Error('Wrong builder database.');
${script}
`, 'utf8');
  try {
    const { stdout } = await execute(resolveMongosh(), [uri, '--quiet', '--norc', '--file', file], {
      timeout: 20_000, windowsHide: true, maxBuffer: 16 * 1024 * 1024,
    });
    const result = JSON.parse(stdout.trim().split(/\r?\n/).filter(Boolean).at(-1));
    if (result.ok !== 1) throw new BuilderMongoError(`Mongo operation failed in ${database}.`);
    return result;
  } catch (error) {
    if (error instanceof BuilderMongoError) throw error;
    throw new BuilderMongoError(`Mongo operation unavailable in ${database}${error.code === 'ENOENT' ? ': mongosh missing' : ''}.`);
  } finally {
    await fs.unlink(file);
  }
}

export async function checkBuilderDatabase() {
  const probeId = randomUUID();
  const value = randomUUID();
  const result = await runBuilderMongo(BUILDER_MONGO_DB, `
const probeId = ${JSON.stringify(probeId)};
const value = ${JSON.stringify(value)};
db.backend_checks.insertOne({ _id: probeId, owner: 'builder-round-trip-v1', value, at: new Date() });
if (db.backend_checks.findOne({ _id: probeId })?.value !== value) throw new Error('insert/read mismatch');
db.backend_checks.updateOne({ _id: probeId }, { $set: { value: value + '-updated' } });
if (db.backend_checks.findOne({ _id: probeId })?.value !== value + '-updated') throw new Error('update/read mismatch');
print(JSON.stringify({ ok: 1, database: db.getName(), probeId, checks: ['insert','read','update','read'], at: new Date().toISOString() }));
`);
  if (result.database !== BUILDER_MONGO_DB || result.probeId !== probeId) {
    throw new BuilderMongoError('Builder database returned an invalid round-trip receipt.');
  }
  return result;
}
