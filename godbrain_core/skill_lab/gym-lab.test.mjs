import assert from 'node:assert/strict';
import test from 'node:test';
import { addToCart, assertGymMongoUri, checkout, cmsCreatePage, cmsLogin, getOrders, getPages, GYM_MONGO_DB, pingGymMongo, readCart, seedCms, seedShop } from './gym-lab-db.mjs';

test('gym Mongo URI fail-closes anything except godbrain_gym', () => {
  assert.equal(assertGymMongoUri('mongodb://127.0.0.1:27017/godbrain_gym'), 'mongodb://127.0.0.1:27017/godbrain_gym');
  assert.throws(() => assertGymMongoUri('mongodb://127.0.0.1:27017/godbrain'), /never Alexandria godbrain/);
  assert.throws(() => assertGymMongoUri('mongodb://127.0.0.1:27017/admin'), /godbrain_gym/);
  assert.throws(() => assertGymMongoUri('mongodb://127.0.0.1:27017/'), /Got none|godbrain_gym/);
});

let mongo = false;
try {
  const ping = await pingGymMongo();
  mongo = ping.ok === 1 && ping.db === GYM_MONGO_DB;
} catch {
  mongo = false;
}

test('godbrain_gym shop checkout persists an order and isolates run ids', { skip: !mongo }, async () => {
  const ping = await pingGymMongo();
  assert.equal(ping.db, 'godbrain_gym');
  const runA = `shop-test-a-${Date.now()}`;
  const runB = `shop-test-b-${Date.now()}`;
  const products = [
    { sku: 'sku-a', title: 'Harbor Lamp', price: 20 },
    { sku: 'sku-b', title: 'Nimbus Mug', price: 8 },
  ];
  await seedShop(runA, products);
  await seedShop(runB, [{ sku: 'sku-z', title: 'Other Desk', price: 50 }]);
  const empty = await checkout(runA, 'buyer@example.test');
  assert.equal(empty.ok, 0);
  const cart = await addToCart(runA, 'sku-a');
  assert.equal(cart.ok, 1);
  assert.equal(cart.lines[0].qty, 1);
  const twice = await addToCart(runA, 'sku-a');
  assert.equal(twice.lines[0].qty, 2);
  const unknown = await addToCart(runA, 'missing');
  assert.equal(unknown.ok, 0);
  const order = await checkout(runA, 'buyer@example.test');
  assert.equal(order.ok, 1);
  assert.equal(order.email, 'buyer@example.test');
  assert.equal(order.total, 40);
  const held = await readCart(runA);
  assert.deepEqual(held.lines, []);
  const listed = await getOrders(runA);
  assert.equal(listed.orders.length, 1);
  assert.equal(listed.orders[0].lines[0].sku, 'sku-a');
  const other = await getOrders(runB);
  assert.equal(other.orders.length, 0);
});

test('godbrain_gym CMS rejects bad passwords and stores a published page', { skip: !mongo }, async () => {
  const runId = `cms-test-${Date.now()}`;
  await seedCms(runId, 'editor1', 'secret-1');
  const denied = await cmsLogin(runId, 'editor1', 'nope');
  assert.equal(denied.ok, 0);
  const session = await cmsLogin(runId, 'editor1', 'secret-1');
  assert.equal(session.ok, 1);
  assert.ok(session.token);
  const unauthorized = await cmsCreatePage(runId, 'bad-token', 'Nope', 'x');
  assert.equal(unauthorized.ok, 0);
  const created = await cmsCreatePage(runId, session.token, 'Dispatch Board', 'Trippus-style body');
  assert.equal(created.ok, 1);
  const listed = await getPages(runId);
  assert.equal(listed.pages.length, 1);
  assert.equal(listed.pages[0].title, 'Dispatch Board');
});
