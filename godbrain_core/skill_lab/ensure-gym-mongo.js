const gym = db.getSiblingDB("godbrain_gym");
gym.products.createIndex({ runId: 1, sku: 1 }, { unique: true });
gym.carts.createIndex({ runId: 1 }, { unique: true });
gym.orders.createIndex({ runId: 1, orderId: 1 }, { unique: true });
gym.cms_users.createIndex({ runId: 1, username: 1 }, { unique: true });
gym.cms_pages.createIndex({ runId: 1, slug: 1 }, { unique: true });
gym.cms_sessions.createIndex({ token: 1 }, { unique: true });
gym.meta.updateOne(
  { _id: "university-lab" },
  {
    $set: {
      createdAt: new Date(),
      purpose: "Frontend University shop/CMS exams. Never the Alexandria godbrain database.",
    },
  },
  { upsert: true },
);
print(JSON.stringify({ ok: 1, db: gym.getName(), collections: gym.getCollectionNames() }));
