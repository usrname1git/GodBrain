import { createHash, randomUUID } from 'node:crypto';
import { existsSync } from 'node:fs';
import { promises as fs } from 'node:fs';
import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';

const directory = path.dirname(fileURLToPath(import.meta.url));
const require = createRequire(import.meta.url);
const { chromium } = require(path.join(directory, '..', 'skill_lab', 'node_modules', 'playwright'));
const { values } = parseArgs({ options: { output: { type: 'string' } } });
if (!values.output || path.extname(values.output).toLowerCase() !== '.png') throw new Error('--output must name a PNG file.');
const token = process.env.GODBRAIN_API_TOKEN;
if (!token?.trim()) throw new Error('A configured bearer is required for the passive status capture.');
const response = await fetch('http://127.0.0.1:8085/api/phone/status', {
  headers: { Authorization: `Bearer ${token}` }, redirect: 'error', signal: AbortSignal.timeout(12000),
});
if (!response.ok) throw new Error(`Passive remote status capture failed (HTTP ${response.status}).`);
const data = await response.json();
for (const group of ['models', 'services', 'core', 'speech']) {
  if (data[group] != null && !Array.isArray(data[group])) throw new Error('Invalid passive capture input.');
  for (const card of data[group] ?? []) {
    if (typeof card.name !== 'string' || /[\\@]|https?:|\b(?:\d{1,3}\.){3}\d{1,3}\b/i.test(card.name)) {
      throw new Error('Unsafe or invalid status card identity.');
    }
    card.detail = 'Passive status; private details omitted.';
  }
}
data.gpu.detail = 'Private sensor details omitted.';
let html = await fs.readFile(path.join(directory, 'phone.html'), 'utf8');
html = html.replace('<main>', '<main><p class="stamp">Sanitized passive-status capture, not a live dashboard.</p>');
html = html.replace('</head>', '<style>#stamp{display:none}</style></head>');
const executablePath = process.env.GODBRAIN_BROWSER ?? [
  'C:\\Program Files\\BraveSoftware\\Brave-Browser\\Application\\brave.exe',
  path.join(process.env['ProgramFiles(x86)'] ?? 'C:\\Program Files (x86)', 'Microsoft', 'Edge', 'Application', 'msedge.exe'),
].find(candidate => existsSync(candidate));
const browser = await chromium.launch({
  headless: true, chromiumSandbox: true, executablePath,
  args: ['--disable-gpu', '--disable-background-networking', '--disable-sync', '--no-first-run'],
});
try {
  const context = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 1, serviceWorkers: 'block' });
  await context.route('**/*', async route => {
    const url = new URL(route.request().url());
    if (url.origin !== 'http://capture.test' || route.request().method() !== 'GET' || url.search) return route.abort();
    if (url.pathname === '/') return route.fulfill({ contentType: 'text/html', body: html });
    if (url.pathname === '/api/phone/status') return route.fulfill({ json: data });
    return route.abort();
  });
  const page = await context.newPage();
  await page.goto('http://capture.test/', { waitUntil: 'networkidle' });
  if (!await page.locator('#error').isHidden()) throw new Error('Remote capture did not render valid current status.');
  if (await page.locator('h1').textContent() !== 'Remote Dashboard') throw new Error('Remote capture title is invalid.');
  if (await page.evaluate(() => document.documentElement.scrollWidth > innerWidth)) throw new Error('Mobile capture overflows.');
  const bytes = await page.screenshot({ fullPage: true });
  await fs.mkdir(path.dirname(path.resolve(values.output)), { recursive: true });
  const temporary = `${values.output}.${randomUUID()}.tmp`;
  try {
    await fs.writeFile(temporary, bytes, { flag: 'wx' });
    await fs.rename(temporary, values.output);
  } finally {
    try { await fs.unlink(temporary); } catch (error) { if (error.code !== 'ENOENT') throw error; }
  }
  console.log(JSON.stringify({ id: 'PHONEDASHBOARD', sha256: createHash('sha256').update(bytes).digest('hex'), kind: 'live-sanitized-source-ui' }));
} finally { await browser.close(); }
