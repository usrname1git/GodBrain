import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {readFile, writeFile, mkdir} from 'node:fs/promises';
import {createRequire} from 'node:module';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {parseArgs} from 'node:util';

const directory = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(directory, '..', '..');
const require = createRequire(import.meta.url);
const {chromium} = require(path.join(directory, '..', 'skill_lab', 'node_modules', 'playwright'));
const {values} = parseArgs({options: {image: {type: 'string'}, output: {type: 'string'}}});
assert.ok(['WORKSPACEMAP', 'WORKSPACEENV', 'WORKSPACEEVAL', 'IOSWORKFLOW', 'CLIPSHAREFLOW'].includes(values.image), 'Unknown named capture');
assert.equal(path.extname(values.output || '').toLowerCase(), '.png', '--output must name a PNG');
const origin = 'http://127.0.0.1:32168';
const sourceHashes = {};
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
async function source(relative) {
  const bytes = await readFile(path.join(root, relative));
  sourceHashes[relative] = sha256(bytes);
  return bytes;
}
async function native(endpoint, body) {
  assert.ok(process.env.GODBRAIN_API_TOKEN?.trim(), 'Configured bearer required for protected native captures');
  const response = await fetch('http://127.0.0.1:8083' + endpoint, {
    method: body === undefined ? 'GET' : 'POST', redirect: 'error',
    headers: {Authorization: 'Bearer ' + process.env.GODBRAIN_API_TOKEN, 'Content-Type': 'application/json'},
    body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(15000),
  });
  assert.ok(response.ok, `Native capture ${endpoint}: HTTP ${response.status}`);
  const bytes = Buffer.from(await response.arrayBuffer());
  sourceHashes['native:' + endpoint] = sha256(bytes);
  return JSON.parse(bytes.toString('utf8'));
}
const browser = await chromium.launch({headless: true,
  executablePath: process.env.GODBRAIN_BROWSER || 'C:\\Program Files\\BraveSoftware\\Brave-Browser\\Application\\brave.exe',
  args: ['--disable-gpu', '--disable-background-networking', '--disable-sync', '--no-first-run']});
try {
  const page = await browser.newPage({viewport: {width: 1440, height: 1000}, serviceWorkers: 'block'});
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  if (values.image === 'CLIPSHAREFLOW') {
    const html = await source('godbrain_core\\showcase\\clipshare-workflow.html');
    await page.route('**/*', route => {
      assert.equal(route.request().url(), origin + '/');
      return route.fulfill({contentType: 'text/html', body: html});
    });
    await page.goto(origin + '/');
  } else if (values.image === 'IOSWORKFLOW') {
    const docs = (await source('docs\\phone-control.md')).toString('utf8');
    await source('scripts\\Start-RustDesk.ps1');
    assert.ok(docs.includes('Run Script Over SSH') && docs.includes('RustDesk remote-desktop service ready'), 'Workflow evidence changed');
    const html = `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>iOS Shortcut Workflows</title><style>
      *{box-sizing:border-box}body{margin:0;background:#0d1727;color:#eef4ff;font:20px system-ui;padding:64px}
      small{color:#91bddc;letter-spacing:.12em}h1{font-size:54px;margin:18px 0}p{color:#afbed0;line-height:1.65}
      .flow{display:flex;gap:24px;margin:48px 0}.step{flex:1;border:1px solid #395370;background:#142339;border-radius:24px;padding:30px}
      .number{color:#73d0cc;font-weight:700;font-size:32px}.step h2{font-size:25px}code{font-size:17px;color:#9adbd7;overflow-wrap:anywhere}
      .boundary{border-left:4px solid #73d0cc;padding:20px 28px;background:#162b3b;border-radius:0 18px 18px 0}
      footer{margin-top:34px;color:#899fb7;font-size:16px}
      </style></head><body><small>IPHONE + WINDOWS / EXISTING PRIVATE BRIDGES</small><h1>Your PC in your pocket.</h1>
      <p>RustDesk does not need to remain running. An explicit authenticated action starts and verifies its Windows backend before you connect.</p>
      <div class="flow"><section class="step"><div class="number">01</div><h2>Tap the Shortcut</h2><p>Run Script Over SSH<br>Key-authenticated, over Tailscale.</p><code>Start-RustDesk.ps1</code></section>
      <section class="step"><div class="number">02</div><h2>Verify the backend</h2><p>The Windows helper checks the service and its SYSTEM-owned backend, not just a GUI window.</p><code>remote-desktop service ready</code></section>
      <section class="step"><div class="number">03</div><h2>Open RustDesk</h2><p>Continue using the existing desktop, Command Center and local tools through the mobile client.</p><code>Existing client authentication</code></section></div>
      <div class="boundary"><strong>Overview and control remain separate.</strong><p>Remote Dashboard is private and read-only. SSH and RustDesk are explicit actions. The PC must be awake and reachable; administrative rights, installed tools and CS2 holds still apply.</p></div>
      <footer>Source-bound workflow illustration / not a captured iPhone screen / no live connection or device test claimed.<br>Sources: docs\\phone-control.md + scripts\\Start-RustDesk.ps1. Private credentials and addresses omitted.</footer></body></html>`;
    await page.route('**/*', route => {
      assert.equal(route.request().url(), origin + '/');
      return route.fulfill({contentType: 'text/html', body: html});
    });
    await page.goto(origin + '/');
  } else {
    const assets = new Map();
    for (const name of ['workspace.html', 'workspace.css', 'workspace.js', 'tidal.svg', 'courtyard.svg'])
      assets.set(name, await source('godbrain_core\\frontend\\' + name));
    const graph = await native('/api/graph?limit=80');
    assert.ok(Array.isArray(graph.nodes) && graph.nodes.length > 0 && graph.nodes.length <= 80, 'Bounded graph required');
    const aliases = new Map(graph.nodes.map((node, index) => [node.id, (index + 1).toString(16).padStart(24, '0')]));
    const nodes = graph.nodes.filter(node => node.group !== 'personal').map((node, index) => ({
      ...node, id: aliases.get(node.id), stable_id: (index + 1).toString(16).padStart(64, '0'),
      title: `Technical record ${String(index + 1).padStart(2, '0')}`, label: `Technical record ${index + 1}`,
    }));
    const technicalIds = new Set(nodes.map(node => node.id));
    const sanitizedGraph = {...graph, nodes, links: graph.links.map(link => ({
      source: aliases.get(link.source), target: aliases.get(link.target), kind: link.kind,
    })).filter(link => technicalIds.has(link.source) && technicalIds.has(link.target)), generation: 'capture-time generation / identifiers redacted'};
    const documents = new Map(nodes.map(node => [node.id, {...node, sector: node.group,
      content: 'Private title, record content and source identity omitted from this public capture.\n\nThe displayed status is the real native capture-time status. This screenshot is not current readiness or permission to replay a repair.'}]));
    let context, working = [];
    if (values.image === 'WORKSPACEENV') {
      context = await native('/api/context', {query: '', thread_id: 'workspace', scope: 'technical'});
      assert.equal(context.state, 'ready');
      context = {...context, context: 'PUBLIC REDACTION / UNTRUSTED ENVIRONMENT REFERENCE\n\nExisting native host and capability map: available\nScope: technical\nHost hardware/software values: omitted from public capture\nGranted roots and private work continuity: omitted\n\nThe stored map is timestamped and bounded, not a complete software inventory.\nAvailability and readiness require current probes.\nIndex refresh is an explicit authenticated action; it grants no permissions.'};
    }
    if (values.image === 'WORKSPACEEVAL') {
      const data = await native('/api/shelf', {action: 'read', shelf: 'research', scope: 'technical', query: 'model-evaluation', limit: 20});
      assert.equal(data.trust, 'untrusted'); assert.equal(data.promoted, false);
      working = data.records.filter(row => /^model[- ]evaluation\b/i.test(row.title)).map((row, index) => ({
        _id: (index + 1).toString(16).padStart(64, '0'), scope: 'technical', trust: 'untrusted',
        title: 'model-evaluation / operator-reviewed response',
        text: 'An actual working model assessment, retained separately from SRE admission.\n\nOriginal request, answer, model attribution and operator reason omitted from the public capture.\n\nTrust: working / untrusted\nRAG promotion: none\n\nCorrectness assessment is not a troubleshooting procedure.',
        sources: [], created_at: row.created_at,
      }));
      assert.ok(working.length, 'No model evaluation exists; do not substitute a sample');
    }
    await page.addInitScript(() => {
      sessionStorage.setItem('godbrain_write_token', 'capture-only-not-a-server-token');
      sessionStorage.setItem('godbrain-workspace-wallpaper', 'tidal');
    });
    await page.route('**/*', route => {
      const url = new URL(route.request().url());
      assert.equal(url.origin, origin, 'Capture must not call external or live control APIs');
      const name = url.pathname.split('/').at(-1);
      if (assets.has(name)) return route.fulfill({body: assets.get(name), contentType: name.endsWith('.html') ? 'text/html' : name.endsWith('.js') ? 'text/javascript' : name.endsWith('.css') ? 'text/css' : 'image/svg+xml'});
      if (url.pathname === '/api/graph') return route.fulfill({json: sanitizedGraph});
      if (url.pathname === '/api/node') return route.fulfill({json: documents.get(url.searchParams.get('id'))});
      if (url.pathname === '/api/context' && context) return route.fulfill({json: context});
      if (url.pathname === '/api/shelf' && JSON.parse(route.request().postData()).action === 'read')
        return route.fulfill({json: {schema_version: 'working-shelf-v1', status: 'ok', trust: 'untrusted', promoted: false, records: working}});
      throw new Error('Capture refused control or unexpected endpoint: ' + url.pathname);
    });
    await page.goto(origin + '/frontend/workspace.html');
    await page.waitForSelector('#review-record');
    if (values.image !== 'WORKSPACEMAP') {
      const shelf = values.image === 'WORKSPACEENV' ? 'environment' : 'evaluations';
      await page.locator(`[data-shelf="${shelf}"]`).click();
      await page.waitForFunction(() => !document.getElementById('result-count').textContent.includes('Loading') &&
        document.getElementById('record-content').textContent.length > 50);
    }
    await page.evaluate(() => {
      document.getElementById('footer-state').textContent = 'PUBLIC CAPTURE / private content and identifiers redacted / not current readiness';
      document.getElementById('connection-label').textContent = 'Sanitized capture-time data';
    });
  }
  assert.deepEqual(errors, []);
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false);
  const bytes = await page.screenshot({fullPage: true});
  await mkdir(path.dirname(path.resolve(values.output)), {recursive: true});
  await writeFile(values.output, bytes, {flag: 'wx'});
  const receipt = {id: values.image, sha256: sha256(bytes), at: new Date().toISOString(),
    kind: ['IOSWORKFLOW', 'CLIPSHAREFLOW'].includes(values.image) ? 'source-workflow-illustration' : 'live-sanitized-source-ui', sourceHashes};
  await writeFile(values.output + '.receipt.json', JSON.stringify(receipt, null, 2) + '\n', {flag: 'wx'});
  console.log(JSON.stringify({id: receipt.id, sha256: receipt.sha256, kind: receipt.kind, sourceBound: true}));
} finally {await browser.close();}
