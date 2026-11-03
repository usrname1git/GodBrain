import { createHash } from 'node:crypto';
import { existsSync } from 'node:fs';
import { promises as fs } from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';
import { buildBundle, outputText } from './browser.mjs';
import { hashFiles } from './gym-core.mjs';
import { loadProjectCatalog } from './project-assets.mjs';

const directory = path.dirname(fileURLToPath(import.meta.url));
const digest = value => createHash('sha256').update(value).digest('hex');
export const PROJECT_PROFILE = 'client-project-assets-v1';

export async function evaluateProjectCandidate({ task, taskId, files, artifactDir, seed = 1, workDir, browserPath } = {}) {
  if (task?.objectiveMode !== 'explore' || task.retainLesson !== false || !task.clientProjectIds?.length) {
    throw new Error('Project image evaluation is restricted to non-qualifying client explorations.');
  }
  const checks = [], errors = [], artifacts = [], blocked = [];
  const check = (name, passed, detail) => { checks.push({ name, passed: Boolean(passed), detail }); if (!passed) errors.push(`${name}: ${detail}`); };
  const fingerprint = createHash('sha256');
  for (const name of ['project-browser.mjs', 'project-assets.mjs', 'browser.mjs', 'package-lock.json']) {
    fingerprint.update(name).update(await fs.readFile(path.join(directory, name)));
  }
  const evaluatorVersion = `${PROJECT_PROFILE}:${fingerprint.digest('hex')}`;
  let catalogHash = null, visualFingerprint = null;
  let server, browserServer, timer, shutdown;
  const stop = () => shutdown ??= browserServer?.kill();
  try {
    const names = Object.keys(files ?? {}).sort().join('\0');
    if (!['App.jsx\0styles.css', 'App.tsx\0styles.css'].includes(names) ||
        Object.values(files).some(value => typeof value !== 'string' || value.length > 64_000 || value.includes('\0'))) {
      throw new Error('Only bounded App.jsx/App.tsx and styles.css are accepted.');
    }
    const catalog = await loadProjectCatalog(workDir, task.clientProjectIds);
    if (!catalog?.projects.length) throw new Error('Selected project catalog is unavailable.');
    catalogHash = catalog.catalogHash;
    const built = await buildBundle(files);
    const prefix = `/fixture-${seed}`;
    const assets = new Map([...catalog.assets].map(([url, asset]) => [prefix + url, asset]));
    const assetRequest = key => assets.get(key);
    const projects = catalog.projects.map(project => ({
      ...project, images: project.images.map(image => ({ ...image, url: `.${prefix}${image.url.slice(1)}` })),
    }));
    const props = { objectiveTitle: task.title, objectiveSeed: seed, projects };
    const routes = new Map([
      ['/', ['text/html; charset=utf-8', '<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><link rel="stylesheet" href="/bundle.css"></head><body><div id="root"></div><script src="/props.js"></script><script src="/bundle.js"></script></body></html>']],
      ['/props.js', ['text/javascript; charset=utf-8', `window.__GODBRAIN_TASK_PROPS__=${JSON.stringify(props).replace(/</g, '\\u003c')};`]],
      ['/bundle.js', ['text/javascript; charset=utf-8', outputText(built, '.js')]],
      ['/bundle.css', ['text/css; charset=utf-8', outputText(built, '.css')]],
    ]);
    server = http.createServer((request, response) => {
      const url = new URL(request.url, 'http://127.0.0.1');
      const key = `${url.pathname}${url.search}`;
      const asset = assetRequest(key);
      const route = request.method === 'GET' ? routes.get(key) : null;
      response.setHeader('X-Content-Type-Options', 'nosniff');
      response.setHeader('Cache-Control', 'no-store');
      response.setHeader('Content-Security-Policy', "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self'; connect-src 'none'; frame-src 'none'; worker-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'");
      if (request.method !== 'GET' || (!route && !asset)) { response.writeHead(404); response.end(); return; }
      response.writeHead(200, { 'Content-Type': asset?.type ?? route[0] });
      response.end(asset?.bytes ?? route[1]);
    });
    await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
    const origin = `http://127.0.0.1:${server.address().port}`;
    const executablePath = browserPath ?? process.env.GODBRAIN_BROWSER ?? [
      'C:\\Program Files\\BraveSoftware\\Brave-Browser\\Application\\brave.exe',
      path.join(process.env['ProgramFiles(x86)'] ?? 'C:\\Program Files (x86)', 'Microsoft', 'Edge', 'Application', 'msedge.exe'),
      path.join(process.env.ProgramFiles ?? 'C:\\Program Files', 'Google', 'Chrome', 'Application', 'chrome.exe'),
    ].find(candidate => existsSync(candidate));
    browserServer = await chromium.launchServer({
      executablePath, host: '127.0.0.1', headless: true, chromiumSandbox: true, timeout: 12_000,
      args: ['--disable-gpu', '--disable-extensions', '--disable-background-networking', '--disable-sync', '--no-first-run', '--dns-prefetch-disable', '--js-flags=--max-old-space-size=256'],
    });
    if (browserServer.process().spawnargs.includes('--no-sandbox')) throw new Error('Refusing an unsandboxed client browser.');
    timer = setTimeout(() => { errors.push('Browser evaluation exceeded 28 seconds.'); stop().catch(error => errors.push(`Browser termination failed: ${error.message}`)); }, 28_000);
    const browser = await chromium.connect(browserServer.wsEndpoint(), { timeout: 12_000 });
    const context = await browser.newContext({ acceptDownloads: false, serviceWorkers: 'block' });
    await context.exposeBinding('__reportProjectPolicyViolation', (_source, detail) => {
      if (blocked.length < 32) blocked.push(`CSP: ${String(detail).slice(0, 180)}`);
    });
    await context.addInitScript(() => {
      const report = window.__reportProjectPolicyViolation;
      document.addEventListener('securitypolicyviolation', event => {
        report(`${event.violatedDirective} ${event.blockedURI}`);
      }, true);
      for (const name of ['RTCPeerConnection', 'webkitRTCPeerConnection', 'WebTransport', 'Worker', 'SharedWorker']) {
        Object.defineProperty(window, name, { value: undefined, writable: false, configurable: false });
      }
    });
    context.setDefaultTimeout(2500);
    await context.route('**/*', route => {
      const url = new URL(route.request().url()), key = `${url.pathname}${url.search}`;
      if (url.origin === origin && route.request().method() === 'GET' && (routes.has(key) || assetRequest(key))) {
        return route.continue();
      }
      if (blocked.length < 32) blocked.push(`${route.request().method()} ${url.href.slice(0, 180)}`);
      return route.abort('blockedbyclient');
    });
    await context.routeWebSocket('**/*', socket => { blocked.push('WebSocket denied'); socket.close(); });
    const page = await context.newPage();
    context.on('page', popup => { if (popup !== page) { blocked.push('Popup denied'); popup.close().catch(error => errors.push(error.message)); } });
    page.on('dialog', dialog => { blocked.push('Dialog denied'); dialog.dismiss().catch(error => errors.push(error.message)); });
    page.on('pageerror', error => { if (errors.length < 32) errors.push(`Browser: ${error.message.slice(0, 400)}`); });
    for (const [view, width, height] of [['desktop', 1280, 850], ['mobile', 390, 844]]) {
      await page.setViewportSize({ width, height });
      await page.goto(origin, { waitUntil: 'networkidle', timeout: 10_000 });
      check(`${view}-content`, await page.locator('main').count() === 1 && await page.locator('h1').count() > 0 &&
        (await page.locator('body').innerText()).trim().length >= 80, 'Requires visible main content and heading.');
      check(`${view}-overflow`, await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), 'Page must fit the viewport.');
      for (const project of projects) {
        const cover = project.images.find(image => image.id === project.cover);
        const expected = new URL(cover.url, `${origin}/`).href;
        const loaded = await page.locator('img').evaluateAll((images, url) =>
          images.some(image => {
            const bounds = image.getBoundingClientRect();
            if (image.src !== url || !image.complete || image.naturalWidth <= 0 ||
                bounds.width <= 0 || bounds.height <= 0) return false;
            let left = Math.max(bounds.left, 0), right = Math.min(bounds.right, innerWidth);
            let top = Math.max(bounds.top, -scrollY);
            let bottom = Math.min(bounds.bottom, document.documentElement.scrollHeight - scrollY);
            for (let node = image; node; node = node.parentElement) {
              const style = getComputedStyle(node);
              if (style.visibility !== 'visible' || Number(style.opacity) <= 0) return false;
              if (node !== image && node !== document.scrollingElement) {
                const clip = node.getBoundingClientRect();
                if (style.overflowX !== 'visible') {
                  left = Math.max(left, clip.left + node.clientLeft);
                  right = Math.min(right, clip.left + node.clientLeft + node.clientWidth);
                }
                if (style.overflowY !== 'visible') {
                  top = Math.max(top, clip.top + node.clientTop);
                  bottom = Math.min(bottom, clip.top + node.clientTop + node.clientHeight);
                }
              }
            }
            return right > left && bottom > top;
          }), expected);
        check(`${view}-cover-${project.id}`, loaded, 'Selected project cover must visibly render within the captured page using the current catalog asset.');
      }
      if (await page.evaluate(() => document.documentElement.scrollHeight > 8192)) throw new Error('Client page exceeds the bounded screenshot height.');
      const image = await page.screenshot({ fullPage: true, animations: 'disabled', timeout: 4000 });
      if (view === 'desktop') visualFingerprint = digest(image);
      if (artifactDir) {
        await fs.mkdir(artifactDir, { recursive: true });
        const target = path.join(artifactDir, `${view}.png`);
        await fs.writeFile(target, image);
        artifacts.push(target);
      }
    }
    check('asset-isolation', blocked.length === 0, blocked.length ? blocked.join('; ') : 'Only the selected hash-bound assets and trusted bundles were requested.');
  } catch (error) {
    check('client-project-render', false, error.message.slice(0, 1200));
  } finally {
    clearTimeout(timer);
    try { if (browserServer) await stop(); }
    finally {
      if (server?.listening) {
        server.closeAllConnections();
        await new Promise((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
      }
    }
  }
  const result = {
    taskId, seed, sourceHash: hashFiles(files ?? {}), evaluatorVersion,
    verificationProfile: PROJECT_PROFILE, catalogHash, visualFingerprint,
    passed: checks.length > 0 && errors.length === 0 && checks.every(item => item.passed),
    checks, errors, artifacts, retainLesson: false,
  };
  if (artifactDir) {
    await fs.mkdir(artifactDir, { recursive: true });
    await fs.writeFile(path.join(artifactDir, 'evidence.json'), `${JSON.stringify(result, null, 2)}\n`);
  }
  return result;
}
