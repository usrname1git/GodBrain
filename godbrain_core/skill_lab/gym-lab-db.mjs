import { execFile } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { existsSync, promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { promisify } from 'node:util';

const execute = promisify(execFile);

export function resolveMongosh() {
  if (process.env.GODBRAIN_MONGOSH) return process.env.GODBRAIN_MONGOSH;
  const local = process.env.LOCALAPPDATA
    ? path.join(process.env.LOCALAPPDATA, 'Programs', 'mongosh', 'mongosh.exe')
    : '';
  if (local && existsSync(local)) return local;
  return 'mongosh';
}

const MONGOSH = resolveMongosh();
export const GYM_MONGO_DB = 'godbrain_gym';

export function assertGymMongoUri(uri) {
  if (typeof uri !== 'string' || !uri.trim()) {
    throw new Error('Gym Mongo URI is missing.');
  }
  let dbName = '';
  try {
    dbName = new URL(uri.replace(/^mongodb(\+srv)?:/i, 'http:')).pathname.replace(/^\//, '').split('/')[0];
  } catch {
    throw new Error('Gym Mongo URI is invalid.');
  }
  if (dbName !== GYM_MONGO_DB) {
    throw new Error(`Gym lab must use database ${GYM_MONGO_DB}, never Alexandria godbrain. Got ${dbName || 'none'}.`);
  }
  return uri;
}

const URI = assertGymMongoUri(process.env.GODBRAIN_GYM_MONGO_URI || `mongodb://127.0.0.1:27017/${GYM_MONGO_DB}`);

function guard(script) {
  return `
if (db.getName() !== ${JSON.stringify(GYM_MONGO_DB)}) {
  print(JSON.stringify({ ok: 0, error: 'wrong database ' + db.getName() }));
  quit();
}
${script}
`;
}

async function mongoFile(script) {
  const file = path.join(os.tmpdir(), `godbrain-gym-${process.pid}-${randomUUID()}.js`);
  await fs.writeFile(file, `${guard(script)}\n`, 'utf8');
  try {
    const { stdout } = await execute(MONGOSH, [URI, '--quiet', '--norc', '--file', file], {
      timeout: 10_000, windowsHide: true, maxBuffer: 1_000_000,
    });
    const line = stdout.trim().split(/\r?\n/).filter(Boolean).at(-1);
    return JSON.parse(line);
  } finally {
    await fs.unlink(file).catch(() => {});
  }
}

export async function pingGymMongo() {
  return mongoFile('print(JSON.stringify({ ok: 1, db: db.getName() }))');
}

export async function seedShop(runId, products) {
  const payload = JSON.stringify(products.map(item => ({
    runId, sku: item.sku, title: item.title, price: item.price,
  })));
  return mongoFile(`
db.products.deleteMany({ runId: ${JSON.stringify(runId)} });
db.carts.deleteMany({ runId: ${JSON.stringify(runId)} });
db.orders.deleteMany({ runId: ${JSON.stringify(runId)} });
db.products.insertMany(${payload});
db.carts.insertOne({ runId: ${JSON.stringify(runId)}, lines: [] });
print(JSON.stringify({ ok: 1, products: ${products.length} }));
`);
}

export async function addToCart(runId, sku) {
  return mongoFile(`
const product = db.products.findOne({ runId: ${JSON.stringify(runId)}, sku: ${JSON.stringify(sku)} });
if (!product) { print(JSON.stringify({ ok: 0, error: 'unknown sku' })); quit(); }
const cart = db.carts.findOne({ runId: ${JSON.stringify(runId)} }) || { lines: [] };
const line = cart.lines.find(item => item.sku === product.sku);
if (line) line.qty += 1;
else cart.lines.push({ sku: product.sku, title: product.title, price: product.price, qty: 1 });
db.carts.updateOne({ runId: ${JSON.stringify(runId)} }, { $set: { lines: cart.lines } }, { upsert: true });
print(JSON.stringify({ ok: 1, lines: cart.lines }));
`);
}

export async function readCart(runId) {
  return mongoFile(`
const cart = db.carts.findOne({ runId: ${JSON.stringify(runId)} }) || { lines: [] };
print(JSON.stringify({ ok: 1, lines: cart.lines || [] }));
`);
}

export async function checkout(runId, email) {
  return mongoFile(`
const cart = db.carts.findOne({ runId: ${JSON.stringify(runId)} });
if (!cart || !cart.lines || !cart.lines.length) { print(JSON.stringify({ ok: 0, error: 'empty cart' })); quit(); }
const total = cart.lines.reduce((sum, line) => sum + line.price * line.qty, 0);
const orderId = ${JSON.stringify(runId)}.slice(0, 8) + '-' + Date.now().toString(36);
db.orders.insertOne({
  runId: ${JSON.stringify(runId)}, orderId, email: ${JSON.stringify(email)},
  lines: cart.lines, total, at: new Date(),
});
db.carts.updateOne({ runId: ${JSON.stringify(runId)} }, { $set: { lines: [] } });
print(JSON.stringify({ ok: 1, orderId, total, email: ${JSON.stringify(email)} }));
`);
}

export async function getOrders(runId) {
  return mongoFile(`
const orders = db.orders.find({ runId: ${JSON.stringify(runId)} }, { _id: 0 }).sort({ at: -1 }).toArray();
print(JSON.stringify({ ok: 1, orders }));
`);
}

export async function seedCms(runId, username, password) {
  return mongoFile(`
db.cms_users.deleteMany({ runId: ${JSON.stringify(runId)} });
db.cms_pages.deleteMany({ runId: ${JSON.stringify(runId)} });
db.cms_sessions.deleteMany({ runId: ${JSON.stringify(runId)} });
db.cms_users.insertOne({
  runId: ${JSON.stringify(runId)}, username: ${JSON.stringify(username)},
  password: ${JSON.stringify(password)},
});
print(JSON.stringify({ ok: 1 }));
`);
}

export async function cmsLogin(runId, username, password) {
  return mongoFile(`
const user = db.cms_users.findOne({
  runId: ${JSON.stringify(runId)},
  username: ${JSON.stringify(username)},
  password: ${JSON.stringify(password)},
});
if (!user) { print(JSON.stringify({ ok: 0, error: 'invalid credentials' })); quit(); }
const token = ${JSON.stringify(runId)} + '-' + Math.random().toString(36).slice(2, 12);
db.cms_sessions.insertOne({
  runId: ${JSON.stringify(runId)}, token, username: user.username, at: new Date(),
});
print(JSON.stringify({ ok: 1, token, username: user.username }));
`);
}

export async function cmsCreatePage(runId, token, title, body) {
  return mongoFile(`
const session = db.cms_sessions.findOne({ runId: ${JSON.stringify(runId)}, token: ${JSON.stringify(token)} });
if (!session) { print(JSON.stringify({ ok: 0, error: 'unauthorized' })); quit(); }
const slug = ${JSON.stringify(title)}.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '') || 'page';
db.cms_pages.updateOne(
  { runId: ${JSON.stringify(runId)}, slug },
  { $set: { title: ${JSON.stringify(title)}, body: ${JSON.stringify(body)}, author: session.username, at: new Date() } },
  { upsert: true },
);
print(JSON.stringify({ ok: 1, slug, title: ${JSON.stringify(title)} }));
`);
}

export async function cmsListPages(runId, token) {
  return mongoFile(`
const session = db.cms_sessions.findOne({ runId: ${JSON.stringify(runId)}, token: ${JSON.stringify(token)} });
if (!session) { print(JSON.stringify({ ok: 0, error: 'unauthorized' })); quit(); }
const pages = db.cms_pages.find({ runId: ${JSON.stringify(runId)} }, { _id: 0 }).toArray();
print(JSON.stringify({ ok: 1, pages }));
`);
}

export async function getPages(runId) {
  return mongoFile(`
const pages = db.cms_pages.find({ runId: ${JSON.stringify(runId)} }, { _id: 0 }).toArray();
print(JSON.stringify({ ok: 1, pages }));
`);
}
