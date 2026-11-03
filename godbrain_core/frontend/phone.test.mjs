import assert from 'node:assert/strict';
import { existsSync } from 'node:fs';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import os from 'node:os';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';

const directory = path.dirname(fileURLToPath(import.meta.url));
const require = createRequire(import.meta.url);
const { chromium } = require(path.join(directory, '..', 'skill_lab', 'node_modules', 'playwright'));
const html = await readFile(path.join(directory, 'phone.html'), 'utf8');
const executablePath = process.env.GODBRAIN_BROWSER ?? (process.platform === 'win32' ? [
  'C:\\Program Files\\BraveSoftware\\Brave-Browser\\Application\\brave.exe',
  path.join(process.env['ProgramFiles(x86)'] ?? 'C:\\Program Files (x86)', 'Microsoft', 'Edge', 'Application', 'msedge.exe'),
].find(candidate => existsSync(candidate)) : undefined);
const launchBrowser = () => chromium.launch({
  headless: true, chromiumSandbox: true, executablePath,
  args: ['--disable-gpu', '--disable-background-networking', '--disable-sync', '--no-first-run'],
});
const card = (name, state = 'ready', detail = 'Live read-only probe') => ({ name, state, detail });
function snapshot() {
  return {
    schema_version: 1, read_only: true, sampled_at: new Date().toISOString(),
    models: [
      { ...card('Qwen EXL3'), port: 8888 },
      { ...card('Qwen-Image-2.1', 'stopped'), port: 8871 },
      { ...card('Legacy mouth', 'stopped'), port: 8000 },
    ],
    services: ['RustDesk', 'Tailscale', 'SSH'].map(name => card(name)),
    core: ['Kernel', 'Alexandria / RAG', 'MongoDB'].map(name => card(name)),
    speech: ['STT', 'TTS', 'CPU OCR'].map(name => card(name, 'available', 'Local assets present; not exercised')),
    gpu: { state: 'ready', used_mib: 15000, total_mib: 16376 },
  };
}

test('Phone Desk mobile rendering, fail-closed states and GET-only polling', async () => {
  const browser = await launchBrowser();
  const requests = [];
  let reply = snapshot(), status = 200, delay = 0, active = 0, maximumActive = 0;
  let pageErrors = 0;
  const page = await browser.newPage({ viewport: { width: 390, height: 844 }, isMobile: true, deviceScaleFactor: 2 });
  page.on('pageerror', () => { pageErrors++; });
  await page.route('http://phone.test/**', async route => {
    const request = route.request();
    const pathname = new URL(request.url()).pathname;
    requests.push({ pathname, method: request.method(), body: request.postData() });
    if (pathname === '/') return route.fulfill({ contentType: 'text/html', body: html });
    assert.equal(pathname, '/api/phone/status', 'Unexpected external or control endpoint');
    active++;
    maximumActive = Math.max(maximumActive, active);
    try {
      if (delay) await new Promise(resolve => setTimeout(resolve, delay));
      await route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(reply) });
    } finally { active--; }
  });
  try {
    await page.goto('http://phone.test/');
    assert.equal(await page.title(), 'Remote Dashboard');
    assert.equal(await page.locator('h1').textContent(), 'Remote Dashboard');
    assert.equal(await page.locator('meta[name="apple-mobile-web-app-title"]').getAttribute('content'), 'Remote Dashboard');
    await page.waitForFunction(() => document.getElementById('models').textContent.includes('Qwen EXL3'));
    assert.equal(await page.locator('#services .card').count(), 3);
    assert.equal(await page.locator('#core .core-row').count(), 3);
    assert.equal(await page.locator('#speech .core-row').count(), 3);
    assert.match(await page.locator('#speech').textContent(), /Available/);
    assert.match(await page.locator('#gpu').textContent(), /14\.6 \/ 16\.0 GiB/);
    assert.ok((await page.locator('#refresh').boundingBox()).height >= 44);
    for (const width of [320, 390, 430, 740]) {
      await page.setViewportSize({ width, height: 844 });
      assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), `Overflow at ${width}px`);
    }

    const refresh = async () => {
      await page.locator('#refresh').click();
      await page.waitForFunction(() => !document.getElementById('refresh').disabled);
    };
    status = 503;
    await refresh();
    assert.equal(await page.locator('#error').isVisible(), true);
    assert.equal(await page.evaluate(() => document.body.classList.contains('stale')), true);
    assert.equal(await page.locator('#models .badge').evaluate(node => getComputedStyle(node).color), 'rgb(195, 183, 168)');
    assert.match(await page.locator('#models').textContent(), /Qwen EXL3/, 'Last-known values disappeared');

    status = 403;
    await refresh();
    assert.match(await page.locator('#error').textContent(), /Access denied/);
    status = 200;
    reply.speech[2] = card('CPU OCR', 'unready', 'No suitable plugin registered for imread.');
    await refresh();
    assert.match(await page.locator('#speech').textContent(), /CPU OCR.*No suitable plugin registered.*Not ready/s);
    delete reply.speech;
    await refresh();
    assert.match(await page.locator('#speech').textContent(), /Unknown/);
    for (const mutate of [
      data => { data.read_only = false; },
      data => { data.services[1] = data.services[0]; },
      data => { data.models = []; },
      data => { data.models[0].state = 'invented'; },
      data => { data.speech[0] = data.speech[1]; },
      data => { data.speech[0].state = 'invented'; },
      data => { data.speech[0].state = ['ready']; },
      data => { data.gpu.used_mib = -1; },
      data => { data.gpu.used_mib = data.gpu.total_mib + 1; },
      data => { data.sampled_at = null; },
      data => { data.sampled_at = new Date(Date.now() - 30000).toISOString(); },
      data => { data.sampled_at = new Date(Date.now() + 60000).toISOString(); },
    ]) {
      reply = snapshot();
      mutate(reply);
      await refresh();
      assert.equal(await page.locator('#error').isVisible(), true, 'Invalid data became current readiness');
    }

    reply = snapshot();
    reply.models[0].name = '<img src=x onerror="window.injected=true">';
    reply.speech[2].detail = '<img src=x onerror="window.injected=true">';
    reply.models[1] = { ...card('Qwen-Image-2.1', 'busy', ':8871 / weights loaded'), port: 8871 };
    reply.gpu = { state: 'unknown', used_mib: null, total_mib: null, detail: 'Sensor unavailable' };
    await refresh();
    assert.equal(await page.locator('#error').isVisible(), false);
    assert.equal(await page.locator('#models img').count(), 0);
    assert.equal(await page.locator('#speech img').count(), 0);
    assert.equal(await page.evaluate(() => window.injected), undefined);
    assert.match(await page.locator('#models').textContent(), /Qwen-Image-2\.1.*weights loaded/s);
    assert.equal(await page.locator('#gpu').textContent(), 'Sensor unavailable');

    await page.evaluate(() => {
      lastSample = new Date(Date.now() - 21000).toISOString();
      updateStamp();
    });
    assert.match(await page.locator('#error').textContent(), /Status is stale/);
    reply = snapshot();
    delay = 350;
    await page.evaluate(() => { refresh(); refresh(); refresh(); });
    await page.waitForFunction(() => !document.getElementById('refresh').disabled);
    assert.equal(maximumActive, 1, 'Overlapping status requests');
    assert.equal(pageErrors, 0);
    assert.ok(requests.length > 10);
    assert.ok(requests.every(request => request.method === 'GET' && request.body === null));
  } finally { await browser.close(); }
});

test('Live mobile route', { skip: process.env.GODBRAIN_PHONE_LIVE_TEST !== '1' }, async () => {
  const serveUrl = process.env.GODBRAIN_PHONE_SERVE_URL;
  if (!serveUrl) assert.ok(process.env.GODBRAIN_API_TOKEN, 'Live check needs GODBRAIN_API_TOKEN');
  const browser = await launchBrowser();
  const page = await browser.newPage({
    viewport: { width: 390, height: 844 }, isMobile: true,
    extraHTTPHeaders: serveUrl ? {} : { Authorization: 'Bearer ' + process.env.GODBRAIN_API_TOKEN },
  });
  const requests = [];
  page.on('request', request => requests.push(request));
  try {
    const response = await page.goto((serveUrl || 'http://127.0.0.1:8085') + '/');
    assert.equal(response.status(), 200);
    await page.waitForFunction(() => document.getElementById('stamp').textContent.startsWith('Checked'));
    assert.equal(await page.locator('#error').isVisible(), false);
    assert.equal(await page.locator('#services .card').count(), 3);
    assert.equal(await page.locator('#core .core-row').count(), 3);
    assert.equal(await page.locator('#speech .core-row').count(), 3);
    assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
    await page.locator('#refresh').click();
    await page.waitForFunction(() => !document.getElementById('refresh').disabled);
    assert.equal(await page.locator('#error').isVisible(), false);
    assert.ok(requests.every(request =>
      request.method() === 'GET' && ['/','/api/phone/status'].includes(new URL(request.url()).pathname)));
  } finally { await browser.close(); }
});

test('passive capture entry point honors an explicit browser and never uses live status in this fixture', { timeout: 60000 }, async t => {
  const work = await mkdtemp(path.join(os.tmpdir(), 'phone-capture-'));
  t.after(() => rm(work, { recursive: true, force: true }));
  const preload = `globalThis.fetch=async (url,options)=>{
    if(url!=='http://127.0.0.1:8085/api/phone/status'||options.headers.Authorization!=='Bearer synthetic-capture-token') throw Error('Unexpected capture request');
    return new Response(${JSON.stringify(JSON.stringify(snapshot()))},{status:200,headers:{'Content-Type':'application/json'}});
  };`;
  const run = browser => promisify(execFile)(process.execPath, [
    '--import', `data:text/javascript,${encodeURIComponent(preload)}`,
    path.join(directory, 'capture-phone.mjs'), '--output', path.join(work, 'capture.png'),
  ], {
    env: { ...process.env, GODBRAIN_API_TOKEN: 'synthetic-capture-token', GODBRAIN_BROWSER: browser },
    timeout: 20000, maxBuffer: 65536, windowsHide: true,
  });
  const missing = path.join(work, 'nonexistent-browser.exe');
  await assert.rejects(run(missing), error => error.stderr.includes('nonexistent-browser.exe'));
  const selected = executablePath ?? chromium.executablePath();
  const { stdout } = await run(selected);
  assert.equal(JSON.parse(stdout).id, 'PHONEDASHBOARD');
  const bytes = await readFile(path.join(work, 'capture.png'));
  assert.equal(bytes.subarray(0, 8).toString('hex'), '89504e470d0a1a0a');
});
