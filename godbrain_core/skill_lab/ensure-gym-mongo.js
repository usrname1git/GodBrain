const db = db.getSiblingDB("godbrain_gym");
db.products.createIndex({ runId: 1, sku: 1 }, { unique: true });
db.carts.createIndex({ runId: 1 }, { unique: true });
db.orders.createIndex({ runId: 1, orderId: 1 }, { unique: true });
db.cms_users.createIndex({ runId: 1, username: 1 }, { unique: true });
db.cms_pages.createIndex({ runId: 1, slug: 1 }, { unique: true });
db.cms_sessions.createIndex({ token: 1 }, { unique: true });
db.meta.updateOne(
  { _id: "university-lab" },
  {
    $set: {
      createdAt: new Date(),
      purpose: "Frontend University shop/CMS exams. Never the Alexandria godbrain database.",
    },
  },
  { upsert: true },
);
print(JSON.stringify({ ok: 1, db: db.getName(), collections: db.getCollectionNames() }));
