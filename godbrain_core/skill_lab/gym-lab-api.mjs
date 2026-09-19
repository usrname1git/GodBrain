import {
  addToCart, checkout, cmsCreatePage, cmsListPages, cmsLogin, readCart, seedCms, seedShop,
} from './gym-lab-db.mjs';

export const LAB_TASKS = Object.freeze({
  'shop-cart-checkout-v1': 'shop',
  'cms-admin-session-v1': 'cms',
});

export function labPaths(kind) {
  if (kind === 'shop') return ['/api/lab/products', '/api/lab/cart', '/api/lab/checkout'];
  if (kind === 'cms') return ['/api/lab/login', '/api/lab/pages'];
  return [];
}

function send(response, status, body) {
  response.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
  });
  response.end(JSON.stringify(body));
}

async function readBody(request) {
  const chunks = [];
  for await (const chunk of request) chunks.push(chunk);
  const raw = Buffer.concat(chunks).toString('utf8');
  if (!raw.trim()) return {};
  return JSON.parse(raw);
}

export async function handleLabApi(request, response, lab) {
  const url = new URL(request.url, 'http://127.0.0.1');
  if (!url.pathname.startsWith('/api/lab/')) return false;
  try {
    if (lab.kind === 'shop') {
      if (request.method === 'GET' && url.pathname === '/api/lab/products') {
        send(response, 200, { ok: 1, products: lab.products });
        return true;
      }
      if (request.method === 'GET' && url.pathname === '/api/lab/cart') {
        send(response, 200, await readCart(lab.runId));
        return true;
      }
      if (request.method === 'POST' && url.pathname === '/api/lab/cart') {
        const body = await readBody(request);
        send(response, 200, await addToCart(lab.runId, String(body.sku ?? '')));
        return true;
      }
      if (request.method === 'POST' && url.pathname === '/api/lab/checkout') {
        const body = await readBody(request);
        send(response, 200, await checkout(lab.runId, String(body.email ?? '')));
        return true;
      }
    }
    if (lab.kind === 'cms') {
      if (request.method === 'POST' && url.pathname === '/api/lab/login') {
        const body = await readBody(request);
        const result = await cmsLogin(lab.runId, String(body.username ?? ''), String(body.password ?? ''));
        send(response, result.ok ? 200 : 401, result);
        return true;
      }
      if (request.method === 'GET' && url.pathname === '/api/lab/pages') {
        const token = request.headers.authorization?.replace(/^Bearer /i, '') ?? '';
        const result = await cmsListPages(lab.runId, token);
        send(response, result.ok ? 200 : 401, result);
        return true;
      }
      if (request.method === 'POST' && url.pathname === '/api/lab/pages') {
        const token = request.headers.authorization?.replace(/^Bearer /i, '') ?? '';
        const body = await readBody(request);
        const result = await cmsCreatePage(lab.runId, token, String(body.title ?? ''), String(body.body ?? ''));
        send(response, result.ok ? 200 : 401, result);
        return true;
      }
    }
    send(response, 404, { ok: 0, error: 'unknown lab route' });
    return true;
  } catch (error) {
    send(response, 500, { ok: 0, error: String(error.message ?? error) });
    return true;
  }
}

export async function prepareLab(kind, runId, props) {
  if (kind === 'shop') {
    await seedShop(runId, props.products);
    return { kind, runId, products: props.products };
  }
  if (kind === 'cms') {
    await seedCms(runId, props.adminUser, props.adminPassword);
    return { kind, runId };
  }
  return null;
}
