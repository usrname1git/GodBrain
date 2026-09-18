import { createHash } from 'node:crypto';
import { promises as fs } from 'node:fs';
import http from 'node:http';
import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { setTimeout as delay } from 'node:timers/promises';
import * as esbuild from 'esbuild';
import { chromium } from 'playwright';
import { getTask } from './curriculum.mjs';
import { validateGeneratedSource } from './verifier-dsl.mjs';

export const EVALUATOR_VERSION = 'browser-evaluator-v4';

const labRoot = path.dirname(fileURLToPath(import.meta.url));
const require = createRequire(import.meta.url);
const SOURCE_LIMIT = 64_000;
const ACTION_TIMEOUT_MS = 2200;
const GLOBAL_TIMEOUT_MS = 28_000;
const BUILD_TIMEOUT_MS = 8000;
const BRAVE_WINDOWS = 'C:\\Program Files\\BraveSoftware\\Brave-Browser\\Application\\brave.exe';

async function bounded(promise, milliseconds, message) {
  let timer;
  try {
    return await Promise.race([
      promise,
      new Promise((resolve, reject) => { timer = setTimeout(() => reject(new Error(message)), milliseconds); }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}

function recordBounded(list, value) {
  if (list.length < 32) list.push(value);
}

function clip(value, limit = 500) {
  const text = String(value ?? '');
  return text.length <= limit ? text : `${text.slice(0, limit)}…`;
}

function hash(value) {
  return createHash('sha256').update(value).digest('hex');
}

function escapeRegExp(value) {
  return String(value).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function namePattern(value) {
  return new RegExp(escapeRegExp(value), 'i');
}

export function navSelectorMismatch(jsx = '', css = '') {
  const hasNav = /<nav[\s>]/i.test(jsx);
  const navClassed = /<nav\b[^>]*className\s*=\s*(?:['"`][^'"`]*\bnav\b|\{[^}]*['"`]nav['"`])/i.test(jsx);
  const hidesDotNav = /\.nav\s*\{[^}]*display\s*:\s*none/i.test(css);
  const hidesElemNav = /(?:^|[{};])\s*nav\s*\{[^}]*display\s*:\s*none/i.test(css);
  if (hasNav && !navClassed && hidesDotNav && !hidesElemNav) {
    return 'CSS hides .nav but markup is <nav> without className="nav". Hide the nav element (nav{display:none} / nav.open{display:flex}), not .nav.';
  }
  return '';
}

export function undefinedCssCustomProperties(css = '') {
  const used = [...css.matchAll(/var\(\s*(--[\w-]+)/gi)].map(match => match[1].toLowerCase());
  if (!used.length) return '';
  const defined = new Set([...css.matchAll(/(--[\w-]+)\s*:/gi)].map(match => match[1].toLowerCase()));
  const missing = [...new Set(used)].filter(name => !defined.has(name));
  if (!missing.length) return '';
  return `styles.css uses ${missing.slice(0, 5).join(', ')} without defining those custom properties. Invalid var() backgrounds compute to transparent (0 tones). Define :root variables or put hex/rgb on .tinted, .dark and cards.`;
}

export function missingMobileNavCss(css = '') {
  const hidesNav = /@media[^{]*max-width[^}]*\{[\s\S]*?(?:^|[{};])\s*nav\s*\{[^}]*display\s*:\s*none/i.test(css)
    || /@media[\s\S]*nav\s*\{[^}]*display\s*:\s*none/i.test(css);
  if (hidesNav) return '';
  return 'styles.css has no @media rule that hides the nav element (nav{display:none}). Put that mobile block next to the desktop nav rules, not at the end of the file, or a 6k rewrite drops it and overflows ~100-180px.';
}

function isHostNetworkFailure(value) {
  return /ERR_NO_BUFFER_SPACE|ERR_INSUFFICIENT_RESOURCES|WSAENOBUFS|ERR_NETWORK_IO_SUSPENDED/i.test(String(value ?? ''));
}

function overflowDetail(prefix, files = {}) {
  const mismatch = navSelectorMismatch(files['App.jsx'] || files['App.tsx'] || '', files['styles.css'] || '');
  return mismatch ? `${prefix} ${mismatch}` : prefix;
}

function failureResult({ taskId, seed, check, detail, artifactDir, sourceHash = null, artifacts = [] }) {
  return writeEvidence({
    artifactDir, taskId, seed, sourceHash,
    checks: [{ name: check, passed: false, detail }],
    errors: [`${check}: ${detail}`], artifacts,
  });
}

async function writeEvidence({ artifactDir, taskId, seed, sourceHash, checks, errors, artifacts, extra = {} }) {
  const passed = checks.length > 0 && errors.length === 0 && checks.every(check => check.passed);
  const result = {
    passed, checks, errors, artifacts,
    evaluatorVersion: EVALUATOR_VERSION, seed, taskId, sourceHash, ...extra,
  };
  if (artifactDir) {
    await fs.mkdir(artifactDir, { recursive: true });
    const evidencePath = path.join(artifactDir, 'evidence.json');
    await fs.writeFile(evidencePath, `${JSON.stringify({
      taskId, seed, sourceHash, evaluatorVersion: EVALUATOR_VERSION,
      passed, checks, errors, ...extra,
    }, null, 2)}\n`);
    result.artifacts = [...artifacts, evidencePath];
  }
  return result;
}

function validateFiles(files) {
  if (!files || Array.isArray(files) || typeof files !== 'object') {
    return 'files must contain one React application file and styles.css.';
  }
  const names = Object.keys(files).sort();
  const jsx = ['App.jsx', 'styles.css'].sort().join('\0');
  const tsx = ['App.tsx', 'styles.css'].sort().join('\0');
  if (![jsx, tsx].includes(names.join('\0'))) {
    return 'Only App.jsx or App.tsx plus styles.css are accepted; paths, configs, scripts, and extra files are rejected.';
  }
  for (const name of names) {
    if (typeof files[name] !== 'string' || files[name].length > SOURCE_LIMIT || files[name].includes('\0')) {
      return `${name} must be a bounded UTF-8 source string without NUL bytes.`;
    }
  }
  const appFile = Object.hasOwn(files, 'App.tsx') ? 'App.tsx' : 'App.jsx';
  if (!files[appFile].trim()) return `${appFile} is empty.`;
  return null;
}

function validateAuthoredImports(source, css) {
  const allowed = new Set(['react', './styles.css']);
  const importLike = /\b(?:import|export)\s+(?:[^'"()]*?\s+from\s*)?['"]([^'"]+)['"]/g;
  const dynamicImport = /\bimport\s*\(\s*['"]([^'"]+)['"]\s*\)/g;
  const requireCall = /\brequire\s*\(\s*['"]([^'"]+)['"]\s*\)/g;
  for (const matcher of [importLike, dynamicImport, requireCall]) {
    for (const match of source.matchAll(matcher)) {
      if (matcher === dynamicImport) return `Dynamic import is not available in the gym: ${match[1]}.`;
      if (matcher === requireCall) return `CommonJS require is not available in the browser gym: ${match[1]}.`;
      if (!allowed.has(match[1])) return `Unexpected import "${match[1]}". Only react and ./styles.css are available.`;
    }
  }
  if (/\bimport\.meta\b/.test(source)) return 'import.meta is not available to learner code.';
  if (/@import\b/i.test(css) || /\burl\s*\(/i.test(css)) {
    return 'styles.css may not import or fetch external resources.';
  }
  return null;
}

export async function buildBundle(files) {
  const appFile = Object.hasOwn(files, 'App.tsx') ? 'App.tsx' : 'App.jsx';
  const appLoader = appFile === 'App.tsx' ? 'tsx' : 'jsx';
  const entry = `import * as __React from 'react';
import { createRoot } from 'react-dom/client';
import App from './${appFile}';
import './styles.css';

const props = window.__GODBRAIN_TASK_PROPS__;
createRoot(document.getElementById('root')).render(__React.createElement(App, props));
`;
  const plugin = {
    name: 'godbrain-student-files',
    setup(build) {
      build.onResolve({ filter: /.*/ }, args => {
        if (args.namespace !== 'student') return null;
        if (args.path === 'react') return { path: require.resolve('react') };
        if (args.path === './styles.css') return { path: 'styles.css', namespace: 'student' };
        return { errors: [{ text: `Unexpected student import "${args.path}". Only react and ./styles.css are available.` }] };
      });
      build.onResolve({ filter: /^trusted-entry\.jsx$/ }, () => ({ path: 'trusted-entry.jsx', namespace: 'trusted' }));
      build.onResolve({ filter: /^\.(?:\/|\\)App\.(?:jsx|tsx)$/ }, args =>
        args.path.endsWith(appFile) ? { path: appFile, namespace: 'student' } :
          { errors: [{ text: `Unexpected application file "${args.path}".` }] });
      build.onResolve({ filter: /^\.(?:\/|\\)styles\.css$/ }, () => ({ path: 'styles.css', namespace: 'student' }));
      build.onResolve({ filter: /^(react|react-dom\/client)$/ }, args => ({
        path: require.resolve(args.path),
      }));
      build.onLoad({ filter: /^trusted-entry\.jsx$/, namespace: 'trusted' }, () => ({ contents: entry, loader: 'jsx' }));
      build.onLoad({ filter: /^App\.(?:jsx|tsx)$/, namespace: 'student' }, () => ({
        contents: `import * as __React from 'react';\n${files[appFile]}`, loader: appLoader,
      }));
      build.onLoad({ filter: /^styles\.css$/, namespace: 'student' }, () => ({ contents: files['styles.css'], loader: 'css' }));
    },
  };
  const context = await esbuild.context({
      entryPoints: ['trusted-entry.jsx'],
      absWorkingDir: labRoot,
      bundle: true,
      write: false,
      outdir: 'out',
      format: 'iife',
      platform: 'browser',
      target: ['chrome120'],
      jsx: 'transform',
      jsxFactory: '__React.createElement',
      jsxFragment: '__React.Fragment',
      logLevel: 'silent',
      plugins: [plugin],
      metafile: false,
      sourcemap: false,
      legalComments: 'none',
  });
  try {
    return await bounded(context.rebuild(), BUILD_TIMEOUT_MS, 'Build timed out.');
  } finally {
    await context.cancel();
    await context.dispose();
  }
}

export function outputText(result, extension) {
  return result.outputFiles.find(file => file.path.endsWith(extension))?.text ?? '';
}

function seeded(seed) {
  let state = (seed >>> 0) || 1;
  return () => {
    state += 0x6D2B79F5;
    let t = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function pick(random, values) {
  return values[Math.floor(random() * values.length) % values.length];
}

function godCycleProps(taskId, seed, random, names) {
  const routes = [
    { id: `inbox-${seed}`, label: `Inbox ${seed}`, title: `Inbox title ${seed}`, body: `${pick(random, names)} queued item ${seed}.` },
    { id: `catalog-${seed}`, label: `Catalog ${seed}`, title: `Catalog title ${seed}`, body: `Browse the seeded index for ${seed}.` },
    { id: `lab-${seed}`, label: `Lab ${seed}`, title: `Lab title ${seed}`, body: `Crash recovery lab ${seed}.` },
  ];
  const records = Array.from({ length: 3 }, (_, index) => ({
    id: `rec-${seed}-${index}`,
    title: `${pick(random, names)} record ${seed}-${index}`,
    detail: `Detail ${seed} row ${index + 1}.`,
  }));
  const adjectives = ['Copper', 'Velvet', 'Quartz', 'Nimbus', 'Olive', 'Solar', 'Harbor', 'Juniper'];
  const nouns = ['Lamp', 'Desk', 'Mug', 'Chair', 'Planter', 'Backpack', 'Speaker', 'Notebook'];
  const groups = ['Alpha', 'Bravo', 'Charlie'];
  const items = Array.from({ length: 96 }, (_, index) => ({
    id: `item-${seed}-${index}`,
    name: `${adjectives[index % adjectives.length]} ${nouns[index % nouns.length]} ${seed}-${index}`,
    group: groups[index % groups.length],
  }));
  const shared = {
    workspace: `Workbench ${seed}`,
    routes,
    records,
    errorMessage: `Load failed ${seed}`,
    emptyLabel: `No records ${seed}`,
    items,
    panelTitle: `Live panel ${seed}`,
    crashLabel: `Crash panel ${seed}`,
    fallbackTitle: `Recovered fallback ${seed}`,
    recoveryLabel: `Reset lab ${seed}`,
  };
  if (taskId === 'client-routing-v1') return { workspace: shared.workspace, routes };
  if (taskId === 'async-data-states-v1') {
    return { records, errorMessage: shared.errorMessage, emptyLabel: shared.emptyLabel };
  }
  if (taskId === 'error-boundary-recovery-v1') {
    return {
      panelTitle: shared.panelTitle,
      crashLabel: shared.crashLabel,
      fallbackTitle: shared.fallbackTitle,
      recoveryLabel: shared.recoveryLabel,
    };
  }
  if (taskId === 'large-list-performance-v1') return { items };
  return shared;
}

export function taskProps(taskId, seed) {
  const random = seeded(seed);
  const names = ['Ada Rivers', 'Bryn Vale', 'Cora Finch', 'Dax Stone', 'Eli Moss', 'Faye Nova'];
  const themes = [
    { id: 'aurora', label: 'Aurora' },
    { id: 'ember', label: 'Ember' },
    { id: 'lagoon', label: 'Lagoon' },
    { id: 'meadow', label: 'Meadow' },
  ];
  if (taskId === 'settings-persistence-v1') {
    const name = pick(random, names);
    return {
      initialName: name,
      initialEmail: `${name.toLowerCase().replace(/\s+/g, '.')}@example.test`,
      themes,
      wantsUpdates: random() > 0.5,
      storageKey: `gb-settings-${seed}-${Math.floor(random() * 9999)}`,
    };
  }
  if (taskId === 'task-list-productivity-v1') {
    const nouns = ['backlog', 'invoice', 'launch notes', 'access review', 'demo script', 'support queue'];
    const first = `Review ${pick(random, nouns)}`;
    const second = `Draft ${pick(random, nouns)}`;
    const third = `Ship ${pick(random, nouns)}`;
    return {
      initialTasks: [
        { id: `t-${seed}-1`, title: first, done: false },
        { id: `t-${seed}-2`, title: second, done: true },
        { id: `t-${seed}-3`, title: third, done: false },
      ],
      newTaskTitle: `Follow up ${pick(random, nouns)} ${seed}`,
      storageKey: `gb-tasks-${seed}-${Math.floor(random() * 9999)}`,
    };
  }
  if (taskId === 'catalog-search-sort-v1') {
    const adjectives = ['Copper', 'Velvet', 'Quartz', 'Nimbus', 'Olive', 'Solar', 'Harbor', 'Juniper'];
    const nouns = ['Lamp', 'Desk', 'Mug', 'Chair', 'Planter', 'Backpack', 'Speaker', 'Notebook'];
    const categories = ['Office', 'Home', 'Travel'];
    const products = Array.from({ length: 7 }, (_, index) => {
      const category = categories[(index + seed) % categories.length];
      return {
        sku: `sku-${seed}-${index}`,
        name: `${pick(random, adjectives)} ${nouns[(index + seed) % nouns.length]} ${seed + index}`,
        category,
        price: 18 + ((seed * 7 + index * 13) % 91),
        rating: Number((3.1 + (((seed + index * 5) % 19) / 10)).toFixed(1)),
      };
    });
    return { products, categories };
  }
  if (taskId === 'registration-validation-v1') {
    return {
      inviteCode: `JOIN-${seed}-${Math.floor(random() * 900 + 100)}`,
      minAge: 18 + (seed % 5),
      reservedNames: [`Admin ${seed}`, `Guest ${Math.floor(random() * 50)}`],
    };
  }
  if (taskId === 'keyboard-tabs-dialog-v1') {
    const labels = ['Overview', 'Metrics', 'History', 'Owners'];
    const suffix = Math.floor(random() * 900 + 100);
    return {
      tabs: labels.map((label, index) => ({
        id: `${label.toLowerCase()}-${seed}`,
        label: `${label} ${suffix + index}`,
        content: `${label} panel evidence for seed ${seed}: ${pick(random, names)} owns item ${index + 1}.`,
      })),
      dialogTitle: `Details ${seed}`,
      dialogBody: `Seed ${seed} dialog body ${pick(random, ['alpha', 'bravo', 'charlie', 'delta'])}.`,
      actionLabel: `Open details ${seed}`,
    };
  }
  if ([
    'client-routing-v1',
    'async-data-states-v1',
    'error-boundary-recovery-v1',
    'large-list-performance-v1',
    'react-god-workbench-v1',
  ].includes(taskId)) {
    return godCycleProps(taskId, seed, random, names);
  }
  if ([
    'marketing-site-architecture-v1',
    'responsive-site-navigation-v1',
    'feature-lifecycle-explorer-v1',
    'pricing-demo-conversion-v1',
    'event-platform-showcase-v1',
  ].includes(taskId)) {
    const brands = ['Northline', 'LumaWorks', 'Gatherly', 'Fieldnote'];
    const products = ['Event Operations Cloud', 'Audience Experience Platform', 'Program Management Suite'];
    const brand = pick(random, brands);
    return {
      brand,
      product: pick(random, products),
      tagline: `Plan, engage and learn with ${brand}`,
      sections: [
        { id: `platform-${seed}`, label: 'Platform' },
        { id: `lifecycle-${seed}`, label: 'Lifecycle' },
        { id: `solutions-${seed}`, label: 'Solutions' },
        { id: `trust-${seed}`, label: 'Trust' },
        { id: `demo-${seed}`, label: 'Demo' },
      ],
      primaryCta: `Book a demo ${seed}`,
      secondaryCta: `Explore the platform ${seed}`,
      proofPoints: [
        'Configurable registration and communication workflows',
        'Live attendee operations and engagement tools',
        'Post-event surveys and reporting in one workspace',
      ],
      lifecycle: [
        { stage: 'Before', summary: `Prepare every touchpoint for program ${seed}.`, features: ['Invitations', 'Registration', 'Payments'] },
        { stage: 'During', summary: `Coordinate the live experience for program ${seed}.`, features: ['Check-in', 'Event app', 'Live polls'] },
        { stage: 'After', summary: `Turn feedback into the next plan for program ${seed}.`, features: ['Surveys', 'Reports', 'Follow-up'] },
      ],
      plans: [
        { name: `Launch ${seed}`, description: 'For focused event teams.', features: ['Registration', 'Communication', 'Reports'] },
        { name: `Scale ${seed}`, description: 'For multi-program organizations.', features: ['Payments', 'Event app', 'Engagement'] },
        { name: `Partner ${seed}`, description: 'For agencies and complex operations.', features: ['Workspaces', 'Lead tools', 'Advanced support'] },
      ],
      eventTypes: ['Conference', 'Corporate event', 'Course', 'Hybrid event'],
    };
  }
  throw new Error(`No seed generator for task ${taskId}.`);
}

async function existingBrowserPath(explicit) {
  const candidates = explicit ? [explicit] : process.platform === 'win32' ? [
    BRAVE_WINDOWS,
    path.join(process.env['ProgramFiles(x86)'] ?? 'C:\\Program Files (x86)', 'Microsoft', 'Edge', 'Application', 'msedge.exe'),
    path.join(process.env.ProgramFiles ?? 'C:\\Program Files', 'Google', 'Chrome', 'Application', 'chrome.exe'),
  ] : [];
  for (const candidate of candidates) {
    try {
      const stat = await fs.stat(candidate);
      if (!stat.isFile()) throw new Error('Not a file.');
      return candidate;
    } catch (error) {
      if (explicit || error.code !== 'ENOENT') throw new Error(`Browser executable is not available: ${candidate}`);
    }
  }
  return null;
}

function htmlFor(props) {
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>GodBrain frontend gym</title>
  <link rel="stylesheet" href="/bundle.css">
</head>
<body>
  <div id="root"></div>
  <script src="/props.js"></script>
  <script src="/bundle.js"></script>
</body>
</html>`;
}

async function startStaticServer({ bundle, css, props }) {
  const csp = "default-src 'none'; connect-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'none'; object-src 'none'; frame-src 'none'; worker-src 'none'; form-action 'none'; base-uri 'none'; frame-ancestors 'none'";
  const routes = new Map([
    ['/', { status: 200, type: 'text/html; charset=utf-8', body: htmlFor(props) }],
    ['/props.js', { status: 200, type: 'text/javascript; charset=utf-8', body: `window.__GODBRAIN_TASK_PROPS__ = ${JSON.stringify(props).replace(/</g, '\\u003c')};` }],
    ['/bundle.js', { status: 200, type: 'text/javascript; charset=utf-8', body: bundle }],
    ['/bundle.css', { status: 200, type: 'text/css; charset=utf-8', body: css }],
    ['/favicon.ico', { status: 204, type: 'image/x-icon', body: '' }],
  ]);
  const server = http.createServer((request, response) => {
    const url = new URL(request.url, 'http://127.0.0.1');
    const route = request.method === 'GET' ? routes.get(url.pathname) : null;
    response.setHeader('Content-Security-Policy', csp);
    response.setHeader('X-Content-Type-Options', 'nosniff');
    response.setHeader('Referrer-Policy', 'no-referrer');
    response.setHeader('Cache-Control', 'no-store');
    response.setHeader('X-DNS-Prefetch-Control', 'off');
    if (!route || url.search) {
      response.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
      response.end('not found');
      return;
    }
    response.writeHead(route.status, { 'Content-Type': route.type });
    response.end(route.body);
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  return {
    server,
    origin: `http://127.0.0.1:${server.address().port}`,
    allowedPaths: new Set(routes.keys()),
  };
}

async function closeServer(server) {
  await new Promise(resolve => {
    server.closeAllConnections?.();
    server.close(() => resolve());
  });
}

async function closeBrowser(server) {
  if (!server) return;
  // Playwright kills the exact browser process tree it created, including hung renderers.
  await bounded(server.kill(), 8000, 'The owned browser process could not be terminated.');
}

async function visibleText(page, text) {
  const locator = page.getByText(text, { exact: false });
  const deadline = Date.now() + ACTION_TIMEOUT_MS;
  for (;;) {
    const count = await locator.count();
    for (let index = 0; index < count; index++) {
      if (await locator.nth(index).isVisible()) return;
    }
    if (Date.now() >= deadline) throw new Error(`No visible text found: ${text}`);
    await delay(75);
  }
}

async function hiddenText(page, text) {
  const locator = page.getByText(text, { exact: false });
  const count = await locator.count();
  for (let index = 0; index < count; index++) {
    if (await locator.nth(index).isVisible()) {
      throw new Error(`Unexpected visible text: ${text}`);
    }
  }
}

async function fieldByLabel(page, label) {
  const locator = page.getByLabel(namePattern(label)).first();
  await locator.waitFor({ state: 'visible', timeout: ACTION_TIMEOUT_MS });
  return locator;
}

async function buttonByName(page, name) {
  const locator = page.getByRole('button', { name: namePattern(name) }).first();
  await locator.waitFor({ state: 'visible', timeout: ACTION_TIMEOUT_MS });
  return locator;
}

async function selectByLabel(page, label, optionLabel) {
  const locator = await fieldByLabel(page, label);
  await locator.selectOption({ label: optionLabel });
}

async function waitForFocus(locator, detail) {
  const deadline = Date.now() + ACTION_TIMEOUT_MS;
  for (;;) {
    if (await locator.evaluate(element => element === document.activeElement)) return;
    if (Date.now() >= deadline) throw new Error(detail);
    await delay(25);
  }
}

async function storageContains(page, key, value) {
  const stored = await page.evaluate(storageKey => localStorage.getItem(storageKey), key);
  if (!stored || !stored.includes(value)) {
    throw new Error(`localStorage[${key}] did not contain ${value}.`);
  }
}

async function addCheck(checks, errors, name, fn) {
  try {
    const detail = await fn();
    checks.push({ name, passed: true, detail: detail ? clip(detail, 300) : undefined });
  } catch (error) {
    const detail = clip(error.message || error, 600);
    checks.push({ name, passed: false, detail });
    errors.push(`${name}: ${detail}`);
  }
}

async function checkSettings(page, props, checks, errors) {
  await addCheck(checks, errors, 'settings-accessible-controls-and-initial-props', async () => {
    const name = await fieldByLabel(page, 'Display name');
    const email = await fieldByLabel(page, 'Email');
    await fieldByLabel(page, 'Theme');
    await fieldByLabel(page, 'Email updates');
    await buttonByName(page, 'Save preferences');
    if (await name.inputValue() !== props.initialName) throw new Error('Display name was not prefilled from props.');
    if (await email.inputValue() !== props.initialEmail) throw new Error('Email was not prefilled from props.');
    if (await (await fieldByLabel(page, 'Email updates')).isChecked() !== props.wantsUpdates) {
      throw new Error('Email updates did not reflect the initial preference.');
    }
  });
  const updatedName = `${props.initialName} Updated`;
  const updatedEmail = `updated.${props.initialEmail}`;
  const theme = props.themes[1 + (props.themes.length % 2)] ?? props.themes[0];
  const wantsUpdates = !props.wantsUpdates;
  await addCheck(checks, errors, 'settings-save-updates-preview-and-storage', async () => {
    await (await fieldByLabel(page, 'Display name')).fill(updatedName);
    await (await fieldByLabel(page, 'Email')).fill(updatedEmail);
    await selectByLabel(page, 'Theme', theme.label);
    const updates = await fieldByLabel(page, 'Email updates');
    await updates.setChecked(wantsUpdates);
    await (await buttonByName(page, 'Save preferences')).click();
    await visibleText(page, updatedName);
    await visibleText(page, theme.label);
    await storageContains(page, props.storageKey, updatedName);
  });
  await addCheck(checks, errors, 'settings-restores-after-reload', async () => {
    await page.reload({ waitUntil: 'domcontentloaded', timeout: ACTION_TIMEOUT_MS });
    await visibleText(page, updatedName);
    const name = await fieldByLabel(page, 'Display name');
    if (await name.inputValue() !== updatedName) throw new Error('Display name input did not restore saved value.');
    const email = await fieldByLabel(page, 'Email');
    if (await email.inputValue() !== updatedEmail) throw new Error('Email input did not restore saved value.');
    const restoredTheme = await (await fieldByLabel(page, 'Theme')).locator('option:checked').innerText();
    if (restoredTheme !== theme.label) throw new Error('Selected theme did not survive reload.');
    if (await (await fieldByLabel(page, 'Email updates')).isChecked() !== wantsUpdates) {
      throw new Error('Email updates preference did not survive reload.');
    }
  });
}

async function checkTaskList(page, props, checks, errors) {
  await addCheck(checks, errors, 'tasks-render-seeded-items-and-controls', async () => {
    await fieldByLabel(page, 'New task');
    await buttonByName(page, 'Add task');
    for (const label of ['All', 'Active', 'Completed']) await visibleText(page, label);
    for (const task of props.initialTasks) await visibleText(page, task.title);
  });
  const first = props.initialTasks[0];
  const second = props.initialTasks[1];
  await addCheck(checks, errors, 'tasks-add-toggle-filter-delete', async () => {
    await (await fieldByLabel(page, 'New task')).fill(props.newTaskTitle);
    await (await buttonByName(page, 'Add task')).click();
    await visibleText(page, props.newTaskTitle);
    const checkbox = page.getByRole('checkbox', { name: namePattern(first.title) }).first();
    await checkbox.waitFor({ state: 'visible', timeout: ACTION_TIMEOUT_MS });
    await checkbox.click();
    if (!(await checkbox.isChecked())) throw new Error('Task checkbox did not become checked after toggle.');
    await (await buttonByName(page, 'Active')).click();
    await hiddenText(page, first.title);
    await visibleText(page, props.newTaskTitle);
    await (await buttonByName(page, 'Completed')).click();
    await visibleText(page, first.title);
    await hiddenText(page, props.newTaskTitle);
    await (await buttonByName(page, 'All')).click();
    await (await buttonByName(page, `Delete ${second.title}`)).click();
    await hiddenText(page, second.title);
  });
  await addCheck(checks, errors, 'tasks-persist-after-reload', async () => {
    await storageContains(page, props.storageKey, props.newTaskTitle);
    await page.reload({ waitUntil: 'domcontentloaded', timeout: ACTION_TIMEOUT_MS });
    await visibleText(page, props.newTaskTitle);
    await hiddenText(page, second.title);
    const checkbox = page.getByRole('checkbox', { name: namePattern(first.title) }).first();
    if (!(await checkbox.isChecked())) throw new Error('Toggled completion state was not restored.');
  });
}

async function completeProductOrder(page, products) {
  const text = await page.locator('body').innerText({ timeout: ACTION_TIMEOUT_MS });
  const positions = products.map(product => text.indexOf(product.name));
  if (positions.some(position => position < 0) || positions.some((position, index) => index > 0 && position < positions[index - 1])) {
    throw new Error('The complete visible product order did not match the selected sort.');
  }
}

async function checkCatalog(page, props, checks, errors) {
  const byPrice = [...props.products].sort((a, b) => a.price - b.price);
  const byRating = [...props.products].sort((a, b) => b.rating - a.rating);
  const target = props.products[2];
  const other = props.products.find(item => item.name !== target.name && !item.name.toLowerCase().includes(target.name.split(' ')[0].toLowerCase()));
  const category = props.categories.find(value => value !== target.category) ?? target.category;
  await addCheck(checks, errors, 'catalog-renders-seeded-products-and-controls', async () => {
    await fieldByLabel(page, 'Search products');
    await fieldByLabel(page, 'Category');
    await fieldByLabel(page, 'Sort');
    for (const product of props.products) {
      await visibleText(page, product.name);
      await visibleText(page, product.category);
    }
  });
  await addCheck(checks, errors, 'catalog-searches-by-seeded-name', async () => {
    const search = target.name.split(' ')[0].toUpperCase();
    await (await fieldByLabel(page, 'Search products')).fill(search);
    await visibleText(page, target.name);
    if (other) await hiddenText(page, other.name);
    await selectByLabel(page, 'Category', target.category);
    for (const product of props.products) {
      const matches = product.name.toUpperCase().includes(search) && product.category === target.category;
      if (matches) await visibleText(page, product.name);
      else await hiddenText(page, product.name);
    }
  });
  await addCheck(checks, errors, 'catalog-filters-category-and-sorts', async () => {
    await (await fieldByLabel(page, 'Search products')).fill('');
    await selectByLabel(page, 'Category', category);
    for (const product of props.products.filter(item => item.category === category)) await visibleText(page, product.name);
    for (const product of props.products.filter(item => item.category !== category).slice(0, 2)) await hiddenText(page, product.name);
    await selectByLabel(page, 'Category', 'All');
    await selectByLabel(page, 'Sort', 'Price: low to high');
    await completeProductOrder(page, byPrice);
    await selectByLabel(page, 'Sort', 'Rating: high to low');
    await completeProductOrder(page, byRating);
    await selectByLabel(page, 'Sort', 'Name A-Z');
    await completeProductOrder(page, [...props.products].sort((a, b) => a.name.localeCompare(b.name)));
  });
}

async function checkRegistration(page, props, checks, errors) {
  const validName = `Valid User ${props.minAge}`;
  const validEmail = `valid${props.minAge}@example.test`;
  await addCheck(checks, errors, 'registration-controls-validate-empty-submit', async () => {
    for (const label of ['Full name', 'Email', 'Password', 'Age', 'Invite code', 'Accept terms']) await fieldByLabel(page, label);
    await (await buttonByName(page, 'Create account')).click();
    await visibleText(page, 'Email');
    const email = await fieldByLabel(page, 'Email');
    if ((await email.getAttribute('aria-invalid')) !== 'true') throw new Error('Email input did not expose aria-invalid=true.');
    await hiddenText(page, 'Success');
  });
  await addCheck(checks, errors, 'registration-rejects-seeded-invalid-values', async () => {
    await (await fieldByLabel(page, 'Full name')).fill(props.reservedNames[0]);
    await (await fieldByLabel(page, 'Email')).fill('not-an-email');
    await (await fieldByLabel(page, 'Password')).fill('short');
    await (await fieldByLabel(page, 'Age')).fill(String(props.minAge - 1));
    await (await fieldByLabel(page, 'Invite code')).fill('WRONG');
    const terms = await fieldByLabel(page, 'Accept terms');
    if (await terms.isChecked().catch(() => false)) await terms.uncheck();
    await (await buttonByName(page, 'Create account')).click();
    for (const label of ['Full name', 'Email', 'Password', 'Age', 'Invite code', 'Accept terms']) {
      if (await (await fieldByLabel(page, label)).getAttribute('aria-invalid') !== 'true') {
        throw new Error(`${label} did not report its invalid value through aria-invalid.`);
      }
    }
    await hiddenText(page, validEmail);
  });
  await addCheck(checks, errors, 'registration-accepts-valid-submit', async () => {
    await (await fieldByLabel(page, 'Full name')).fill(validName);
    await (await fieldByLabel(page, 'Email')).fill(validEmail);
    await (await fieldByLabel(page, 'Password')).fill('strong-pass-123');
    await (await fieldByLabel(page, 'Age')).fill(String(props.minAge + 2));
    await (await fieldByLabel(page, 'Invite code')).fill(props.inviteCode);
    await (await fieldByLabel(page, 'Accept terms')).check();
    await (await buttonByName(page, 'Create account')).click();
    await visibleText(page, validName);
    await visibleText(page, validEmail);
  });
}

async function checkTabsDialog(page, props, checks, errors) {
  await addCheck(checks, errors, 'tabs-render-roles-and-first-panel', async () => {
    await page.getByRole('tablist').waitFor({ state: 'visible', timeout: ACTION_TIMEOUT_MS });
    for (const tab of props.tabs) await page.getByRole('tab', { name: namePattern(tab.label) }).waitFor({ state: 'visible', timeout: ACTION_TIMEOUT_MS });
    await visibleText(page, props.tabs[0].content);
  });
  await addCheck(checks, errors, 'tabs-keyboard-navigation-selects-panels', async () => {
    const first = page.getByRole('tab', { name: namePattern(props.tabs[0].label) }).first();
    await first.focus();
    await page.keyboard.press('ArrowRight');
    const second = page.getByRole('tab', { name: namePattern(props.tabs[1].label) }).first();
    if ((await second.getAttribute('aria-selected')) !== 'true') throw new Error('ArrowRight did not select the next tab.');
    await visibleText(page, props.tabs[1].content);
    await waitForFocus(second, 'ArrowRight did not move keyboard focus to the selected tab.');
    await page.keyboard.press('End');
    const last = page.getByRole('tab', { name: namePattern(props.tabs.at(-1).label) }).first();
    if ((await last.getAttribute('aria-selected')) !== 'true') throw new Error('End did not select the last tab.');
    await visibleText(page, props.tabs.at(-1).content);
    await waitForFocus(last, 'End did not move keyboard focus to the last tab.');
    await page.keyboard.press('ArrowLeft');
    const previous = page.getByRole('tab', { name: namePattern(props.tabs.at(-2).label) }).first();
    if (await previous.getAttribute('aria-selected') !== 'true') throw new Error('ArrowLeft did not select the previous tab.');
    await visibleText(page, props.tabs.at(-2).content);
    await waitForFocus(previous, 'ArrowLeft did not move keyboard focus to the previous tab.');
    await page.keyboard.press('Home');
    if (await first.getAttribute('aria-selected') !== 'true') throw new Error('Home did not select the first tab.');
    await visibleText(page, props.tabs[0].content);
    await waitForFocus(first, 'Home did not move keyboard focus to the first tab.');
  });
  await addCheck(checks, errors, 'dialog-opens-closes-and-restores-focus', async () => {
    const opener = await buttonByName(page, props.actionLabel);
    await opener.click();
    await page.getByRole('dialog', { name: namePattern(props.dialogTitle) }).waitFor({ state: 'visible', timeout: ACTION_TIMEOUT_MS });
    await visibleText(page, props.dialogBody);
    const focusedInside = await page.evaluate(() => {
      const dialog = document.querySelector('[role="dialog"]');
      return Boolean(dialog && dialog.contains(document.activeElement));
    });
    if (!focusedInside) throw new Error('Opening the dialog did not move focus inside it.');
    await page.keyboard.press('Escape');
    await page.getByRole('dialog', { name: namePattern(props.dialogTitle) }).waitFor({ state: 'hidden', timeout: ACTION_TIMEOUT_MS });
    await waitForFocus(opener, 'Focus did not return to the dialog opener after Escape.');
    await opener.click();
    await (await buttonByName(page, 'Close details')).click();
    await page.getByRole('dialog', { name: namePattern(props.dialogTitle) }).waitFor({ state: 'hidden', timeout: ACTION_TIMEOUT_MS });
    await waitForFocus(opener, 'The close button did not restore focus to the opener.');
  });
}

async function openLabeledRoute(page, label) {
  if (!label) return;
  const link = page.getByRole('link', { name: namePattern(label) });
  if (await link.count()) await link.first().click();
}

async function checkClientRouting(page, props, checks, errors) {
  await addCheck(checks, errors, 'client-routes-update-hash-and-content', async () => {
    await visibleText(page, props.workspace);
    const second = props.routes[1];
    await page.getByRole('link', { name: namePattern(second.label) }).first().click();
    await visibleText(page, second.title);
    await visibleText(page, second.body);
    const hash = await page.evaluate(() => location.hash);
    if (!hash.includes(second.id)) throw new Error(`location.hash ${hash} did not contain route id ${second.id}.`);
  });
  await addCheck(checks, errors, 'unknown-hash-shows-not-found', async () => {
    await page.evaluate(id => { location.hash = '#/' + id; }, `missing-${props.workspace}`);
    await visibleText(page, 'Not found');
    const stray = page.getByText(props.routes[1].body, { exact: false });
    if (await stray.count() && await stray.first().isVisible()) {
      throw new Error('Unknown hash still showed a real route body.');
    }
  });
  await addCheck(checks, errors, 'browser-back-restores-previous-route', async () => {
    const first = props.routes[0];
    const second = props.routes[1];
    await page.getByRole('link', { name: namePattern(first.label) }).first().click();
    await visibleText(page, first.title);
    await page.getByRole('link', { name: namePattern(second.label) }).first().click();
    await visibleText(page, second.title);
    await page.goBack({ timeout: ACTION_TIMEOUT_MS });
    await visibleText(page, first.title);
  });
}

async function checkAsyncData(page, props, checks, errors) {
  await addCheck(checks, errors, 'resource-status-loading-hides-records', async () => {
    await openLabeledRoute(page, props.routes?.[0]?.label);
    const status = page.getByRole('combobox', { name: /resource status/i });
    await status.waitFor({ state: 'visible', timeout: ACTION_TIMEOUT_MS });
    await status.selectOption('loading');
    await page.getByRole('status').filter({ hasText: /^Loading$/ }).waitFor({ state: 'visible', timeout: ACTION_TIMEOUT_MS });
    const title = page.getByText(props.records[0].title, { exact: false });
    if (await title.count() && await title.first().isVisible()) {
      throw new Error('Loading state still listed a seeded record title.');
    }
  });
  await addCheck(checks, errors, 'resource-status-error-retry-and-empty', async () => {
    const status = page.getByRole('combobox', { name: /resource status/i });
    await status.selectOption('error');
    await page.getByRole('alert').filter({ hasText: props.errorMessage }).waitFor({ state: 'visible', timeout: ACTION_TIMEOUT_MS });
    await (await buttonByName(page, 'Retry')).click();
    await visibleText(page, props.records[0].title);
    await status.selectOption('empty');
    await visibleText(page, props.emptyLabel);
    const title = page.getByText(props.records[1].title, { exact: false });
    if (await title.count() && await title.first().isVisible()) {
      throw new Error('Empty state still listed a seeded record title.');
    }
  });
  await addCheck(checks, errors, 'resource-status-ready-lists-seeded-records', async () => {
    await page.getByRole('combobox', { name: /resource status/i }).selectOption('ready');
    for (const record of props.records) {
      await visibleText(page, record.title);
      await visibleText(page, record.detail);
    }
  });
}

async function checkErrorBoundary(page, props, checks, errors) {
  await addCheck(checks, errors, 'error-boundary-replaces-crashed-child', async () => {
    await openLabeledRoute(page, props.routes?.[2]?.label);
    await visibleText(page, props.panelTitle);
    await (await buttonByName(page, props.crashLabel)).click();
    await visibleText(page, props.fallbackTitle);
    const live = page.getByText(props.panelTitle, { exact: false });
    if (await live.count() && await live.first().isVisible()) {
      throw new Error('The crashed panel title remained visible after the boundary caught the throw.');
    }
  });
  await addCheck(checks, errors, 'error-boundary-reset-restores-panel', async () => {
    await (await buttonByName(page, props.recoveryLabel)).click();
    await visibleText(page, props.panelTitle);
  });
}

async function checkLargeList(page, props, checks, errors, files = {}) {
  await addCheck(checks, errors, 'large-list-renders-seeded-rows-with-keys', async () => {
    await openLabeledRoute(page, props.routes?.[1]?.label);
    const source = `${files['App.jsx'] ?? ''}\n${files['App.tsx'] ?? ''}`;
    if (!/key\s*=\s*\{/.test(source)) throw new Error('The large list source must map with a stable key={...}.');
    await visibleText(page, props.items[0].name);
    await visibleText(page, props.items.at(-1).name);
  });
  await addCheck(checks, errors, 'large-list-filters-a-unique-row-quickly', async () => {
    const target = props.items[70];
    const unrelated = props.items[3];
    const search = page.getByRole('textbox', { name: /search items/i });
    const started = Date.now();
    await search.fill(target.name);
    await visibleText(page, target.name);
    const elapsed = Date.now() - started;
    if (elapsed > 1500) throw new Error(`Filtering ${props.items.length} rows took ${elapsed}ms.`);
    const leftover = page.getByText(unrelated.name, { exact: true });
    if (await leftover.count() && await leftover.first().isVisible()) {
      throw new Error('Search left an unrelated seeded row visible.');
    }
  });
}

async function actionByName(page, name) {
  const pattern = namePattern(name);
  const button = page.getByRole('button', { name: pattern });
  if (await button.count()) return button.first();
  const tab = page.getByRole('tab', { name: pattern });
  if (await tab.count()) return tab.first();
  const link = page.getByRole('link', { name: pattern });
  if (await link.count()) return link.first();
  throw new Error(`No button, tab, or link named "${name}" is visible.`);
}

async function roleByNames(scope, role, names) {
  for (const name of names) {
    const locator = scope.getByRole(role, { name });
    if (await locator.count()) return locator.first();
  }
  return scope.getByRole(role, { name: names[0] });
}

async function formCombobox(page) {
  const form = page.locator('form');
  for (const name of [/event type/i, /\btype\b/i]) {
    const named = form.getByRole('combobox', { name });
    if (await named.count()) return named.first();
  }
  const combo = form.getByRole('combobox');
  if (await combo.count()) return combo.first();
  const select = form.locator('select');
  if (await select.count()) return select.first();
  throw new Error('Missing a native <select> inside the demo form.');
}

async function formEmail(page) {
  const form = page.locator('form');
  for (const name of [/work email/i, /e-?mail/i]) {
    const named = form.getByRole('textbox', { name });
    if (await named.count()) return named.first();
  }
  const typed = form.locator('input[type="email"]');
  if (await typed.count()) return typed.first();
  throw new Error('Missing an email textbox inside the demo form.');
}

async function featureSearch(page) {
  const names = [/search features/i, /search/i, /filter features/i, /filter/i, /find/i];
  for (const role of ['textbox', 'searchbox']) {
    for (const name of names) {
      const named = page.getByRole(role, { name });
      if (await named.count()) return named.first();
    }
  }
  throw new Error('Missing a Search or Filter features textbox.');
}

async function checkMarketingQuality(page, props, checks, errors, draftOnly = false, files = {}) {
  await addCheck(checks, errors, 'semantic-marketing-structure', async () => {
    await page.locator('header').first().waitFor({ state: 'visible' });
    await page.locator('main').first().waitFor({ state: 'visible' });
    await page.locator('footer').first().waitFor({ state: 'visible' });
    if (await page.getByRole('heading', { level: 1 }).count() !== 1) throw new Error('Exactly one h1 is required.');
    if (await page.locator('main h1').count() !== 1) throw new Error('The hero and its h1 must be inside the main landmark.');
    if (await page.getByRole('heading', { level: 2 }).count() < 4) throw new Error('At least four labelled content sections are required.');
    if (await page.locator('main section').count() < 4) throw new Error('The main region needs at least four substantial sections.');
    await visibleText(page, props.brand);
    await visibleText(page, props.product);
    for (const section of props.sections.slice(0, 4)) {
      const links = page.getByRole('link', { name: namePattern(section.label) });
      if (!(await links.count())) {
        throw new Error(`No link named "${section.label}". Header nav must render sections[].label as links.`);
      }
      if (!(await links.first().isVisible())) {
        throw new Error(`Link "${section.label}" exists but is hidden on desktop. Do not put className="menu" on nav or display:none the desktop navigation.`);
      }
    }
    await (await actionByName(page, props.primaryCta)).waitFor({ state: 'visible' });
    await (await actionByName(page, props.secondaryCta)).waitFor({ state: 'visible' });
  });
  await addCheck(checks, errors, 'honest-substantial-content', async () => {
    const text = (await page.locator('main').innerText()).trim();
    if (text.length < 650) throw new Error(`Main content is too thin (${text.length} characters).`);
    if (/\b(?:lorem ipsum|todo|coming soon|placeholder)\b/i.test(text)) throw new Error('Placeholder content is not accepted.');
    if (/\b(?:SOC ?2|ISO ?27001)\s+(?:certified|compliant)|99\.9+%\s+uptime|trusted by\s+\d+|\d+%\s+(?:increase|improvement|faster)\b/i.test(text)) {
      throw new Error('The page contains an unsupported certification, guarantee, customer count, or performance statistic.');
    }
    for (const proof of props.proofPoints.slice(0, 2)) await visibleText(page, proof);
  });
  if (draftOnly) return;
  await addCheck(checks, errors, 'professional-visual-system', async () => {
    const metrics = await page.evaluate(() => {
      const visible = element => {
        const rect = element.getBoundingClientRect();
        const style = getComputedStyle(element);
        return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' && style.display !== 'none';
      };
      const elements = [...document.querySelectorAll('main *')].filter(visible);
      const textElements = elements.filter(element => element.textContent?.trim() &&
        ['P', 'A', 'BUTTON', 'LI', 'LABEL', 'H1', 'H2', 'H3'].includes(element.tagName));
      const colors = new Set();
      const radii = new Set();
      for (const element of elements.slice(0, 240)) {
        const style = getComputedStyle(element);
        if (style.backgroundColor !== 'rgba(0, 0, 0, 0)') colors.add(style.backgroundColor);
        if (/gradient\(/i.test(style.backgroundImage)) colors.add(`gradient:${style.backgroundImage}`);
        if (style.borderRadius !== '0px') radii.add(style.borderRadius);
      }
      const fontSizes = textElements.map(element => Number.parseFloat(getComputedStyle(element).fontSize));
      const sectionPadding = [...document.querySelectorAll('main section')].filter(visible).map(element => {
        const style = getComputedStyle(element);
        return Number.parseFloat(style.paddingTop) + Number.parseFloat(style.paddingBottom);
      });
      return {
        bodyFont: Number.parseFloat(getComputedStyle(document.body).fontSize),
        h1Font: Number.parseFloat(getComputedStyle(document.querySelector('h1')).fontSize),
        tinyRatio: fontSizes.length ? fontSizes.filter(size => size < 13).length / fontSizes.length : 1,
        distinctFontSizes: new Set(fontSizes.map(size => Math.round(size))).size,
        colors: colors.size,
        radii: radii.size,
        roomySections: sectionPadding.filter(value => value >= 48).length,
        interactive: document.querySelectorAll('a[href],button,input,select,textarea').length,
      };
    });
    if (metrics.bodyFont < 14 || metrics.bodyFont > 20) throw new Error(`Body typography is not readable (${metrics.bodyFont}px).`);
    if (metrics.h1Font < 36) throw new Error(`Desktop h1 lacks hierarchy (${metrics.h1Font}px).`);
    if (metrics.tinyRatio > 0.18) throw new Error('Too much visible text is smaller than 13px.');
    if (metrics.distinctFontSizes < 4) throw new Error('The typography lacks a deliberate hierarchy.');
    if (metrics.colors < 3) {
      throw new Error(`Need ≥3 distinct tones on visible main descendants; found ${metrics.colors}. CSS gradients now count; keep .tinted/.dark/hero from collapsing onto the same white as cards.`);
    }
    if (metrics.roomySections < 3) throw new Error('Section spacing is too compressed for a premium marketing page.');
    if (metrics.interactive < 7) throw new Error('The page lacks meaningful navigation and conversion interactions.');
  });
  await addCheck(checks, errors, 'intentional-mobile-composition', async () => {
    await page.setViewportSize({ width: 390, height: 844 });
    const metrics = await page.evaluate(() => ({
      overflow: Math.max(0, document.documentElement.scrollWidth - window.innerWidth),
      bodyFont: Number.parseFloat(getComputedStyle(document.body).fontSize),
      h1Font: Number.parseFloat(getComputedStyle(document.querySelector('h1')).fontSize),
      wideElements: [...document.querySelectorAll('body *')].filter(element => {
        const rect = element.getBoundingClientRect();
        return rect.width > window.innerWidth + 2;
      }).length,
    }));
    if (metrics.overflow > 2 || metrics.wideElements) {
      throw new Error(overflowDetail('Mobile composition overflows the viewport.', files));
    }
    if (metrics.bodyFont < 14 || metrics.h1Font < 28) throw new Error('Mobile typography collapses below readable hierarchy.');
    await page.setViewportSize({ width: 1280, height: 850 });
  });
}

async function checkMarketingArchitecture(page, props, checks, errors) {
  await addCheck(checks, errors, 'seeded-marketing-content', async () => {
    for (const proof of props.proofPoints) await visibleText(page, proof);
    for (const section of props.sections) await visibleText(page, section.label);
  });
}

async function checkResponsiveNavigation(page, props, checks, errors) {
  await addCheck(checks, errors, 'responsive-menu-opens-closes', async () => {
    await page.setViewportSize({ width: 390, height: 844 });
    const menu = page.getByRole('button', { name: /^menu$/i }).first();
    await menu.waitFor({ state: 'visible' });
    if (await menu.getAttribute('aria-expanded') !== 'false') throw new Error('The closed menu must expose aria-expanded=false.');
    await menu.click();
    if (await menu.getAttribute('aria-expanded') !== 'true') throw new Error('Opening the menu did not set aria-expanded=true.');
    for (const section of props.sections) {
      await page.getByRole('link', { name: namePattern(section.label) }).first().waitFor({ state: 'visible' });
    }
    await page.keyboard.press('Escape');
    if (await menu.getAttribute('aria-expanded') !== 'false') throw new Error('Escape did not close the mobile navigation.');
    await page.setViewportSize({ width: 1280, height: 850 });
  });
}

async function checkLifecycleExplorer(page, props, checks, errors) {
  await addCheck(checks, errors, 'lifecycle-stages-change-content', async () => {
    for (const stage of props.lifecycle) {
      await (await actionByName(page, stage.stage)).click();
      await visibleText(page, stage.summary);
      for (const feature of stage.features) await visibleText(page, feature);
    }
  });
  await addCheck(checks, errors, 'feature-search-filters-seeded-content', async () => {
    const target = props.lifecycle[0].features[0];
    const unrelated = props.lifecycle[1].features[0];
    const search = await featureSearch(page);
    await search.fill(target.slice(0, Math.max(3, target.length - 2)));
    await visibleText(page, target);
    const unrelatedLocator = page.getByText(unrelated, { exact: false });
    if (await unrelatedLocator.count() && await unrelatedLocator.first().isVisible()) {
      throw new Error('Feature search left an unrelated feature visible.');
    }
  });
}

async function checkPricingDemo(page, props, checks, errors) {
  await addCheck(checks, errors, 'plans-render-comparable-seeded-content', async () => {
    for (const plan of props.plans) {
      await visibleText(page, plan.name);
      await visibleText(page, plan.description);
      for (const feature of plan.features) await visibleText(page, feature);
    }
  });
  await addCheck(checks, errors, 'demo-form-validates-before-success', async () => {
    const name = page.locator('form').getByRole('textbox', { name: /name/i });
    const email = await formEmail(page);
    const eventType = await formCombobox(page);
    const submit = page.locator('form').getByRole('button', { name: /book a demo/i });
    await submit.waitFor({ state: 'visible', timeout: ACTION_TIMEOUT_MS });
    await submit.click();
    if (await page.locator('[aria-invalid="true"]').count() < 2) throw new Error('Invalid submission did not mark required fields.');
    const submittedName = `Alex ${props.brand}`;
    await name.fill(submittedName);
    await email.fill(`alex.${props.brand.toLowerCase()}@example.test`);
    await eventType.selectOption({ label: props.eventTypes[0] });
    await submit.click();
    await visibleText(page, submittedName);
  });
}

async function runTaskChecks(taskId, page, props, checks, errors, task, files = {}) {
  if ([
    'marketing-site-architecture-v1',
    'responsive-site-navigation-v1',
    'feature-lifecycle-explorer-v1',
    'pricing-demo-conversion-v1',
    'event-platform-showcase-v1',
  ].includes(taskId)) {
    await checkMarketingQuality(page, props, checks, errors, task.evaluationProfile === 'structure-draft', files);
  }
  if (taskId === 'settings-persistence-v1') return checkSettings(page, props, checks, errors);
  if (taskId === 'task-list-productivity-v1') return checkTaskList(page, props, checks, errors);
  if (taskId === 'catalog-search-sort-v1') return checkCatalog(page, props, checks, errors);
  if (taskId === 'registration-validation-v1') return checkRegistration(page, props, checks, errors);
  if (taskId === 'keyboard-tabs-dialog-v1') return checkTabsDialog(page, props, checks, errors);
  if (taskId === 'marketing-site-architecture-v1') return checkMarketingArchitecture(page, props, checks, errors);
  if (taskId === 'responsive-site-navigation-v1') return checkResponsiveNavigation(page, props, checks, errors);
  if (taskId === 'feature-lifecycle-explorer-v1') return checkLifecycleExplorer(page, props, checks, errors);
  if (taskId === 'pricing-demo-conversion-v1') return checkPricingDemo(page, props, checks, errors);
  if (taskId === 'event-platform-showcase-v1') {
    await checkMarketingArchitecture(page, props, checks, errors);
    await checkResponsiveNavigation(page, props, checks, errors);
    await checkLifecycleExplorer(page, props, checks, errors);
    return checkPricingDemo(page, props, checks, errors);
  }
  if (taskId === 'client-routing-v1') return checkClientRouting(page, props, checks, errors);
  if (taskId === 'async-data-states-v1') return checkAsyncData(page, props, checks, errors);
  if (taskId === 'error-boundary-recovery-v1') return checkErrorBoundary(page, props, checks, errors);
  if (taskId === 'large-list-performance-v1') return checkLargeList(page, props, checks, errors, files);
  if (taskId === 'react-god-workbench-v1') {
    await checkClientRouting(page, props, checks, errors);
    await checkAsyncData(page, props, checks, errors);
    await checkLargeList(page, props, checks, errors, files);
    return checkErrorBoundary(page, props, checks, errors);
  }
  throw new Error(`No browser assertions for task ${taskId}.`);
}

function expectedBoundaryLog(text) {
  return /god-crash|The above error occurred|React will try to recreate this component tree|error boundary/i.test(String(text ?? ''));
}

async function genericChecks(page, checks, errors, pageErrors, blockedRequests, consoleErrors, { ignoreBoundaryLogs = false } = {}) {
  const runtime = ignoreBoundaryLogs ? pageErrors.filter(item => !expectedBoundaryLog(item)) : pageErrors;
  const consoles = ignoreBoundaryLogs ? consoleErrors.filter(item => !expectedBoundaryLog(item)) : consoleErrors;
  await addCheck(checks, errors, 'app-rendered-visible-content', async () => {
    await page.locator('#root').waitFor({ state: 'visible', timeout: ACTION_TIMEOUT_MS });
    const text = (await page.locator('#root').innerText({ timeout: ACTION_TIMEOUT_MS })).trim();
    if (text.length < 3) throw new Error('The React root rendered no meaningful visible content.');
  });
  await addCheck(checks, errors, 'no-runtime-errors', async () => {
    if (runtime.length) throw new Error(runtime.map(item => clip(item, 160)).join(' | '));
  });
  await addCheck(checks, errors, 'no-blocked-network-or-popups', async () => {
    if (blockedRequests.length) throw new Error(JSON.stringify(blockedRequests.slice(0, 4)));
  });
  await addCheck(checks, errors, 'no-console-errors', async () => {
    if (consoles.length) throw new Error(consoles.slice(0, 4).join(' | '));
  });
}

async function captureArtifacts(page, artifactDir, checks, errors, artifacts, files = {}) {
  if (!artifactDir) return;
  await addCheck(checks, errors, 'desktop-and-mobile-screenshots-without-overflow', async () => {
    const desktop = path.join(artifactDir, 'desktop.png');
    const desktopOverflow = await page.evaluate(() => Math.max(0, document.documentElement.scrollWidth - window.innerWidth));
    if (desktopOverflow > 2) throw new Error(overflowDetail(`Desktop layout overflows viewport by ${desktopOverflow}px.`, files));
    await page.screenshot({ path: desktop, fullPage: false, timeout: ACTION_TIMEOUT_MS });
    artifacts.push(desktop);
    await page.setViewportSize({ width: 390, height: 844 });
    await page.screenshot({ path: path.join(artifactDir, 'mobile.png'), fullPage: false, timeout: ACTION_TIMEOUT_MS });
    artifacts.push(path.join(artifactDir, 'mobile.png'));
    const overflow = await page.evaluate(() => Math.max(0, document.documentElement.scrollWidth - window.innerWidth));
    if (overflow > 2) throw new Error(overflowDetail(`Mobile layout overflows viewport by ${overflow}px.`, files));
  });
}

async function designFingerprint(page) {
  const design = await page.evaluate(() => {
    const selectors = ['body', 'header', 'main section', 'h1', 'h2', 'button', 'article'];
    return selectors.map(selector => {
      const element = document.querySelector(selector);
      if (!element) return [selector, null];
      const style = getComputedStyle(element);
      const rect = element.getBoundingClientRect();
      return [selector, {
        color: style.color,
        background: style.backgroundColor,
        font: style.fontFamily,
        size: style.fontSize,
        weight: style.fontWeight,
        radius: style.borderRadius,
        display: style.display,
        width: Math.round(rect.width / 20) * 20,
      }];
    });
  });
  return hash(JSON.stringify(design));
}

export async function evaluateCandidate({
  taskId, files, artifactDir, seed = 1, browserPath, evaluationTimeoutMs = GLOBAL_TIMEOUT_MS,
  task: customTask,
} = {}) {
  const task = customTask ?? getTask(taskId);
  const contractTaskId = task.baseTaskId ?? task.id;
  if (!Number.isSafeInteger(seed)) throw new Error('seed must be a safe integer.');
  if (!Number.isSafeInteger(evaluationTimeoutMs) || evaluationTimeoutMs < 1000 || evaluationTimeoutMs > GLOBAL_TIMEOUT_MS) {
    throw new Error('Browser evaluation timeout must be between 1000 and 28000 milliseconds.');
  }
  const sourceHash = hash(JSON.stringify(files ?? null));
  const appFile = task.appFile ?? (Object.hasOwn(files ?? {}, 'App.tsx') ? 'App.tsx' : 'App.jsx');
  const inputError = validateFiles(files) ??
    validateAuthoredImports(files?.[appFile] ?? '', files?.['styles.css'] ?? '') ??
    validateGeneratedSource(task, files) ??
    (navSelectorMismatch(files?.[appFile] ?? '', files?.['styles.css'] ?? '') || null) ??
    (undefinedCssCustomProperties(files?.['styles.css'] ?? '') || null) ??
    (['marketing-site-architecture-v1', 'responsive-site-navigation-v1', 'feature-lifecycle-explorer-v1', 'pricing-demo-conversion-v1', 'event-platform-showcase-v1'].includes(contractTaskId) &&
      /<nav[\s>]/i.test(files?.[appFile] ?? '')
      ? (missingMobileNavCss(files?.['styles.css'] ?? '') || null)
      : null);
  if (inputError) {
    return failureResult({ taskId: task.id, seed, check: 'source-contract', detail: inputError, artifactDir, sourceHash });
  }
  let built;
  try {
    built = await buildBundle(files);
  } catch (error) {
    return failureResult({
      taskId: task.id, seed, check: 'compile-jsx',
      detail: clip(error.errors?.map(item => item.text).join('; ') || error.message, 900),
      artifactDir, sourceHash,
    });
  }
  const props = task.objectiveMode === 'explore'
    ? { objectiveTitle: task.title, objectiveSeed: seed }
    : taskProps(contractTaskId, seed);
  const propsDigest = hash(JSON.stringify(props));
  const server = await startStaticServer({
    bundle: outputText(built, '.js'),
    css: outputText(built, '.css'),
    props,
  });
  let browser;
  let browserServer;
  let watchdog;
  let expired = false;
  let shutdown;
  const stopBrowser = () => shutdown ??= closeBrowser(browserServer);
  const checks = [];
  const errors = [];
  const artifacts = [];
  const pageErrors = [];
  const consoleErrors = [];
  const blockedRequests = [];
  try {
    const executablePath = await existingBrowserPath(browserPath);
    browserServer = await chromium.launchServer({
      host: '127.0.0.1',
      chromiumSandbox: true,
      executablePath: executablePath ?? undefined,
      headless: true,
      timeout: 12_000,
      args: [
        '--disable-gpu',
        '--dns-prefetch-disable',
        '--force-webrtc-ip-handling-policy=disable_non_proxied_udp',
        '--disable-extensions',
        '--disable-background-networking',
        '--disable-sync',
        '--no-first-run',
        '--no-default-browser-check',
      ],
    });
    if (browserServer.process().spawnargs.includes('--no-sandbox')) {
      throw new Error('Refusing to execute learner code with the Chromium sandbox disabled.');
    }
    browser = await chromium.connect(browserServer.wsEndpoint(), { timeout: 12_000 });
    watchdog = setTimeout(() => {
      expired = true;
      // Renderer hangs can also block page.evaluate(), which has no action timeout.
      // Termination rejects those outstanding protocol calls; cleanup is awaited below.
      stopBrowser().catch(error => recordBounded(pageErrors, `Browser termination failed: ${error.message}`));
    }, evaluationTimeoutMs);
    const context = await browser.newContext({
      viewport: { width: 1280, height: 850 },
      acceptDownloads: false,
      serviceWorkers: 'block',
      javaScriptEnabled: true,
      ignoreHTTPSErrors: false,
    });
    await context.addInitScript(() => {
      for (const name of ['RTCPeerConnection', 'webkitRTCPeerConnection', 'WebTransport', 'Worker', 'SharedWorker']) {
        Object.defineProperty(window, name, { value: undefined, writable: false, configurable: false });
      }
    });
    context.setDefaultTimeout(ACTION_TIMEOUT_MS);
    await context.route('**/*', async route => {
      const request = route.request();
      let url;
      try {
        url = new URL(request.url());
      } catch {
        recordBounded(blockedRequests, { url: clip(request.url(), 180), method: request.method(), resourceType: request.resourceType() });
        await route.abort('blockedbyclient');
        return;
      }
      const allowed = url.origin === server.origin && server.allowedPaths.has(url.pathname) && !url.search;
      if (allowed) {
        await route.continue();
      } else {
        recordBounded(blockedRequests, { url: clip(url.href, 180), method: request.method(), resourceType: request.resourceType() });
        await route.abort('blockedbyclient');
      }
    });
    await context.routeWebSocket('**/*', socket => {
      recordBounded(blockedRequests, { url: clip(socket.url(), 180), method: 'WEBSOCKET', resourceType: 'websocket' });
      socket.close();
    });
    const page = await context.newPage();
    context.on('page', async other => {
      if (other !== page) {
        recordBounded(blockedRequests, { url: clip(other.url(), 180), method: 'POPUP', resourceType: 'document' });
        await other.close().catch(error => recordBounded(pageErrors, `Popup close failed: ${error.message}`));
      }
    });
    page.on('popup', async popup => {
      recordBounded(blockedRequests, { url: clip(popup.url(), 180), method: 'POPUP', resourceType: 'document' });
      await popup.close().catch(error => recordBounded(pageErrors, `Popup close failed: ${error.message}`));
    });
    page.on('dialog', dialog => {
      recordBounded(blockedRequests, { method: 'DIALOG', resourceType: dialog.type() });
      dialog.dismiss().catch(error => recordBounded(pageErrors, `Dialog dismissal failed: ${error.message}`));
    });
    page.on('pageerror', error => recordBounded(pageErrors, clip(error.message, 500)));
    page.on('console', message => {
      if (['error', 'warning'].includes(message.type())) recordBounded(consoleErrors, clip(message.text(), 300));
    });
    try {
      await page.goto(`${server.origin}/`, { waitUntil: 'domcontentloaded', timeout: 9000 });
      checks.push({ name: 'page-loaded', passed: true });
    } catch (error) {
      if (isHostNetworkFailure(error.message)) throw error;
      checks.push({ name: 'page-loaded', passed: false, detail: clip(error.message, 600) });
      errors.push(`page-loaded: ${clip(error.message, 600)}`);
      return await writeEvidence({
        artifactDir, taskId: task.id, seed, sourceHash, checks, errors, artifacts,
        extra: { propsDigest, blockedRequests: blockedRequests.slice(0, 8), pageErrors: pageErrors.slice(0, 8) },
      });
    }
    const ignoreBoundaryLogs = ['error-boundary-recovery-v1', 'react-god-workbench-v1'].includes(contractTaskId);
    await genericChecks(page, checks, errors, pageErrors, blockedRequests, consoleErrors, { ignoreBoundaryLogs });
    const hostNoise = [...consoleErrors, ...pageErrors, ...errors].join('\n');
    if (isHostNetworkFailure(hostNoise)) {
      throw new Error(clip(hostNoise, 400));
    }
    if (task.objectiveMode !== 'explore') {
      await runTaskChecks(contractTaskId, page, props, checks, errors, task, files);
    }
    await genericChecks(page, checks, errors, pageErrors, blockedRequests, consoleErrors, { ignoreBoundaryLogs });
    await captureArtifacts(page, artifactDir, checks, errors, artifacts, files);
    const visualFingerprint = task.qualityProfile ? await designFingerprint(page) : null;
    if (expired) {
      return await failureResult({
        taskId: task.id, seed, artifactDir, sourceHash, artifacts,
        check: 'evaluation-deadline', detail: `Browser execution exceeded ${evaluationTimeoutMs}ms; the owned browser was terminated.`,
      });
    }
    return await writeEvidence({
      artifactDir, taskId: task.id, seed, sourceHash, checks, errors, artifacts,
      extra: {
        propsDigest,
        visualFingerprint,
        propsPreview: clip(JSON.stringify(props), 900),
        consoleErrors: consoleErrors.slice(0, 8),
        pageErrors: pageErrors.slice(0, 8),
        blockedRequests: blockedRequests.slice(0, 8),
      },
    });
  } catch (error) {
    if (!expired) throw error;
    return await failureResult({
      taskId: task.id, seed, artifactDir, sourceHash, artifacts,
      check: 'evaluation-deadline', detail: `Browser execution exceeded ${evaluationTimeoutMs}ms; the owned browser was terminated.`,
    });
  } finally {
    clearTimeout(watchdog);
    try {
      await stopBrowser();
    } finally {
      await closeServer(server.server);
    }
  }
}
