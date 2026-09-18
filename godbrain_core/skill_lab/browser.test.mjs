import assert from 'node:assert/strict';
import { promises as fs } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { buildBundle, evaluateCandidate, EVALUATOR_VERSION, missingMobileNavCss, navSelectorMismatch, outputText, undefinedCssCustomProperties } from './browser.mjs';
import { getTask, TASKS } from './curriculum.mjs';
import { universityAppScaffold } from './gym-core.mjs';
import { getReference, REFERENCES } from './references.mjs';

const labRoot = path.dirname(fileURLToPath(import.meta.url));
const browserPath = 'C:\\Program Files\\BraveSoftware\\Brave-Browser\\Application\\brave.exe';

async function workspace(t) {
  const root = path.join(labRoot, 'work', 'tests');
  await fs.mkdir(root, { recursive: true });
  const dir = await fs.mkdtemp(path.join(root, 'browser-'));
  t.after(() => fs.rm(dir, { recursive: true, force: true }));
  return dir;
}

async function evaluateIn(t, taskId, files, seed = 1) {
  const dir = await workspace(t);
  return evaluateCandidate({
    taskId, files, seed, browserPath,
    artifactDir: path.join(dir, taskId, `seed-${seed}`),
  });
}

async function evidence(result) {
  const file = result.artifacts.find(item => item.endsWith('evidence.json'));
  assert.ok(file, 'evidence.json artifact was recorded');
  return JSON.parse(await fs.readFile(file, 'utf8'));
}

test('curriculum has compact product and marketing-site tasks with strict lookup', () => {
  assert.equal(TASKS.length, 16);
  for (const task of TASKS) {
    assert.equal(getTask(task.id), task);
    assert.ok(task.id && task.family && task.title);
    assert.ok(task.brief.length > 400 && task.brief.length < 2000, task.id);
    assert.ok(Array.isArray(task.docs) && task.docs.length >= 1);
    assert.equal(REFERENCES[task.id]?.['App.jsx']?.includes(task.brief), false);
  }
  assert.throws(() => getTask('missing-task'));
});

test('all reference implementations pass real browser checks on two meaningful seeds', async t => {
  for (const task of TASKS) {
    const digests = new Set();
    for (const seed of [1, 2]) {
      const result = await evaluateIn(t, task.id, getReference(task.id), seed);
      assert.equal(result.evaluatorVersion, EVALUATOR_VERSION);
      assert.equal(result.taskId, task.id);
      assert.equal(result.seed, seed);
      assert.equal(result.passed, true, `${task.id} seed ${seed}: ${JSON.stringify(result.errors)}`);
      assert.ok(result.checks.length >= 7, `${task.id} should have product, security, and evidence checks`);
      assert.ok(result.artifacts.some(item => item.endsWith('desktop.png')));
      assert.ok(result.artifacts.some(item => item.endsWith('mobile.png')));
      const record = await evidence(result);
      assert.equal(record.passed, true);
      digests.add(record.propsDigest);
    }
    assert.equal(digests.size, 2, `${task.id} seeds should produce different inputs`);
  }
});

test('visual-god reference implements the seeded canvas and rejects a generic template', async t => {
  for (const seed of [1, 2]) {
    const result = await evaluateIn(t, 'visual-god-v1', getReference('visual-god-v1'), seed);
    assert.equal(result.passed, true, `seed ${seed}: ${JSON.stringify(result.errors)}`);
  }
  const generic = {
    'App.jsx': `export default function App() {
  return <main style={{ fontFamily: 'Segoe UI, system-ui, sans-serif', background: '#fff', color: '#111' }}>
    <h1 style={{ textAlign: 'center', fontSize: 48 }}>Launch your workspace</h1>
    <a className="cta" href="#x" style={{ background: '#6366f1', color: '#fff' }}>Get started</a>
    <section>{[1, 2, 3].map(index => <article className="card" key={index} style={{ width: 280, display: 'inline-block' }}>Card {index}</article>)}</section>
  </main>;
}`,
    'styles.css': 'body{margin:0}',
  };
  const failed = await evaluateIn(t, 'visual-god-v1', generic, 1);
  assert.equal(failed.passed, false);
  assert.ok((failed.errors || []).some(item => /visual-system-tokens-applied|visual-hero|visual-anti-generic/i.test(item)), JSON.stringify(failed.errors));
});

test('god-cycle reference implementations pass two seeds', async t => {
  const ids = [
    'client-routing-v1',
    'async-data-states-v1',
    'error-boundary-recovery-v1',
    'large-list-performance-v1',
    'react-god-workbench-v1',
  ];
  for (const taskId of ids) {
    for (const seed of [1, 2]) {
      const result = await evaluateIn(t, taskId, getReference(taskId), seed);
      assert.equal(result.passed, true, `${taskId} seed ${seed}: ${JSON.stringify(result.errors)}`);
    }
  }
});

test('lifecycle stages may use the explicit tab role promised by the contract', async t => {
  const files = getReference('feature-lifecycle-explorer-v1');
  files['App.jsx'] = files['App.jsx'].replace(
    '<button key={item.stage} aria-pressed={stage===index}',
    '<button key={item.stage} role="tab" aria-selected={stage===index}',
  );
  const result = await evaluateIn(t, 'feature-lifecycle-explorer-v1', files, 17);
  assert.equal(result.passed, true, JSON.stringify(result.errors));
});

test('demo validation targets the form submit instead of a similarly named hero CTA', async t => {
  const files = getReference('pricing-demo-conversion-v1');
  files['App.jsx'] = files['App.jsx'].replace(
    '<a className="primary" href={\'#\'+sections.at(-1).id}>{primaryCta}</a>',
    '<button className="primary" type="button">{primaryCta}</button>',
  );
  assert.match(files['App.jsx'], /type="button">\{primaryCta\}/);
  const result = await evaluateIn(t, 'pricing-demo-conversion-v1', files, 16);
  assert.equal(result.passed, true, JSON.stringify(result.errors));
});

test('navSelectorMismatch names .nav hide against an unclassed nav element', () => {
  const jsx = '<header><button className="menu">Menu</button><nav aria-label="Primary" className={menu?\'open\':\'\'}>links</nav></header>';
  const miss = '.menu{display:none}@media(max-width:640px){.nav{display:none}.nav.open{display:flex}}';
  const hit = '.menu{display:none}@media(max-width:640px){nav{display:none}nav.open{display:flex}}';
  assert.match(navSelectorMismatch(jsx, miss), /Hide the nav element/);
  assert.equal(navSelectorMismatch(jsx, hit), '');
  assert.equal(navSelectorMismatch('<nav className="nav open">x</nav>', miss), '');
});

test('demo form still finds Name when invalid errors render inside the wrapping label', async t => {
  const files = getReference('event-platform-showcase-v1');
  files['App.jsx'] = files['App.jsx']
    .replace(
      '<label>Name<input aria-invalid={Boolean(errors.name)} value={form.name} onChange={event=>setForm({...form,name:event.target.value})}/></label>{errors.name&&<p className="error">{errors.name}</p>}',
      '<label>Name<input aria-invalid={Boolean(errors.name)} value={form.name} onChange={event=>setForm({...form,name:event.target.value})}/>{errors.name&&<span className="error">{errors.name}</span>}</label>',
    )
    .replace(
      '<label>Work email<input aria-invalid={Boolean(errors.email)} value={form.email} onChange={event=>setForm({...form,email:event.target.value})}/></label>{errors.email&&<p className="error">{errors.email}</p>}',
      '<label>Work email<input aria-invalid={Boolean(errors.email)} value={form.email} onChange={event=>setForm({...form,email:event.target.value})}/>{errors.email&&<span className="error">{errors.email}</span>}</label>',
    );
  const result = await evaluateIn(t, 'event-platform-showcase-v1', files, 27);
  assert.equal(result.passed, true, JSON.stringify(result.errors));
});

test('typed capstone scaffold passes browser checks on two seeds', async t => {
  const files = {
    'App.tsx': universityAppScaffold('App.tsx', 'event-platform-showcase-v1'),
    'styles.css': getReference('event-platform-showcase-v1')['styles.css'],
  };
  for (const seed of [1, 2]) {
    const result = await evaluateIn(t, 'event-platform-showcase-v1', files, seed);
    assert.equal(result.passed, true, `seed ${seed}: ${JSON.stringify(result.errors)}`);
  }
});

test('studio copy may rename Search features and Event type without failing the contract', async t => {
  const files = getReference('event-platform-showcase-v1');
  files['App.jsx'] = files['App.jsx']
    .replace('>Search features<input', '>Filter features<input')
    .replace('<label>Event type<select', '<label>Program type<select')
    .replace('<label>Work email<input', '<label>Email<input');
  assert.match(files['App.jsx'], /Filter features/);
  assert.match(files['App.jsx'], /Program type/);
  assert.match(files['App.jsx'], /<label>Email<input/);
  const result = await evaluateIn(t, 'event-platform-showcase-v1', files, 29);
  assert.equal(result.passed, true, JSON.stringify(result.errors));
});

test('demo form submit accepts Book a demo with a seeded suffix inside form', async t => {
  const files = getReference('event-platform-showcase-v1');
  files['App.jsx'] = files['App.jsx'].replace(
    '<button className="primary">Book a demo</button>',
    '<button type="submit" className="primary">{primaryCta}</button>',
  );
  const result = await evaluateIn(t, 'event-platform-showcase-v1', files, 26);
  assert.equal(result.passed, true, JSON.stringify(result.errors));
});

test('task-list CSS without a nav element is not failed for missing mobile nav', async t => {
  const files = getReference('task-list-productivity-v1');
  files['styles.css'] = files['styles.css'].replace(/@media[\s\S]*$/, '');
  assert.equal(missingMobileNavCss(files['styles.css']).length > 0, true);
  const result = await evaluateIn(t, 'task-list-productivity-v1', files, 25);
  assert.equal(result.passed, true, JSON.stringify(result.errors));
});

test('missing mobile nav media query fails source-contract before overflow', async t => {
  assert.match(missingMobileNavCss('nav{display:flex}.menu{display:none}'), /no @media rule that hides the nav/);
  assert.equal(missingMobileNavCss('@media(max-width:640px){nav{display:none}nav.open{display:flex}}'), '');
  const files = getReference('responsive-site-navigation-v1');
  files['styles.css'] = files['styles.css'].replace(/@media[\s\S]*$/, '');
  const result = await evaluateIn(t, 'responsive-site-navigation-v1', files, 24);
  assert.equal(result.passed, false);
  assert.equal(result.checks[0].name, 'source-contract');
  assert.match(result.errors.join('\n'), /no @media rule that hides the nav/);
});

test('undefined CSS variables fail source-contract before tonal depth', async t => {
  assert.match(
    undefinedCssCustomProperties('.tinted{background:var(--tint)}.dark{background:var(--navy)}'),
    /without defining those custom properties/,
  );
  assert.equal(undefinedCssCustomProperties(':root{--tint:#e6f1ef}.tinted{background:var(--tint)}'), '');
  const files = getReference('event-platform-showcase-v1');
  files['styles.css'] = files['styles.css']
    .replace(/:root,\[[^\]]*\]\{[^}]*\}/g, '')
    .replace(/\[[^\]]*\]\{[^}]*\}/g, '');
  assert.equal(/--tint\s*:/.test(files['styles.css']), false);
  assert.match(files['styles.css'], /var\(--tint\)/);
  const result = await evaluateIn(t, 'event-platform-showcase-v1', files, 23);
  assert.equal(result.passed, false);
  assert.equal(result.checks[0].name, 'source-contract');
  assert.match(result.errors.join('\n'), /without defining those custom properties/);
});

test('gradient section backgrounds still satisfy marketing tonal depth', async t => {
  const files = getReference('event-platform-showcase-v1');
  files['styles.css'] = `main section:nth-child(even){background:#fff}\n${files['styles.css']}`
    .replace('.tinted{background:var(--tint)}', '.tinted{background:linear-gradient(180deg,#eef7f7,#f6f3ec)}')
    .replace('.demo{display:grid;grid-template-columns:1fr 1fr;gap:48px;background:var(--hero)}',
      '.demo{display:grid;grid-template-columns:1fr 1fr;gap:48px;background:linear-gradient(135deg,#fff,#eef7f7)}');
  const result = await evaluateIn(t, 'event-platform-showcase-v1', files, 21);
  assert.equal(result.passed, true, JSON.stringify(result.errors));
  assert.equal(result.errors.some(item => /tonal depth|distinct tones/i.test(item)), false);
});

test('mobile overflow names .nav hide when markup has no className nav', async t => {
  const files = getReference('event-platform-showcase-v1');
  files['styles.css'] = files['styles.css']
    .replace('nav{display:none', '.nav{display:none')
    .replace('nav.open{display:flex}', '.nav.open{display:flex}');
  const result = await evaluateIn(t, 'event-platform-showcase-v1', files, 22);
  assert.equal(result.passed, false);
  assert.equal(result.checks[0].name, 'source-contract');
  assert.match(result.errors.join('\n'), /Hide the nav element|\.nav/);
});

test('desktop nav links fail clearly when className=menu hides them', async t => {
  const files = getReference('marketing-site-architecture-v1');
  files['App.jsx'] = files['App.jsx'].replace(
    '<nav aria-label="Primary" className={menu?\'open\':\'\'}>',
    '<nav aria-label="Primary" className="menu">',
  );
  assert.match(files['App.jsx'], /className="menu"/);
  const result = await evaluateIn(t, 'marketing-site-architecture-v1', files, 19);
  assert.equal(result.passed, false);
  assert.match(result.errors.join('\n'), /No link named|hidden on desktop|className="menu"/);
});

test('marketing hierarchy requires the hero and h1 inside main', async t => {
  const files = getReference('feature-lifecycle-explorer-v1');
  files['App.jsx'] = files['App.jsx']
    .replace('<main id="top">\n      <section className="hero">', '<section className="hero">')
    .replace('</section>\n      <section id={sections[0].id}>',
      '</section>\n      <main id="top"><section id={sections[0].id}>');
  const result = await evaluateIn(t, 'feature-lifecycle-explorer-v1', files, 18);
  assert.equal(result.passed, false);
  assert.match(result.errors.join('\n'), /hero and its h1 must be inside the main landmark/);
});

test('source boundary rejects paths, imports and external CSS before browser execution', async t => {
  const valid = getReference('settings-persistence-v1');
  for (const files of [
    { ...valid, 'package.json': '{}' },
    { 'App.jsx': "import fs from 'node:fs'; export default function App(){return <main>bad</main>}", 'styles.css': '' },
    { 'App.jsx': "import x from './secret.js'; export default function App(){return <main>bad</main>}", 'styles.css': '' },
    { 'App.jsx': 'export default function App(){return <main>bad</main>}', 'styles.css': '@import "https://example.test/x.css";' },
  ]) {
    const result = await evaluateIn(t, 'settings-persistence-v1', files, 3);
    assert.equal(result.passed, false);
    assert.equal(result.checks[0].name, 'source-contract');
    assert.match(result.errors.join('\n'), /Only App|Unexpected import|styles\.css/);
  }
});

test('TypeScript React sources compile without broadening the file boundary', async () => {
  const result = await buildBundle({
    'App.tsx': `type AppProps={name:string};
      export default function App({name}:AppProps){return <main><h1>{name}</h1></main>}`,
    'styles.css': 'main{display:grid}@media(max-width:600px){main{display:block}}',
  });
  assert.match(outputText(result, '.js'), /createRoot/);
  assert.ok(outputText(result, '.css').includes('display'));
});

test('compile errors, fake persistence and network attempts are failed attempts, not infrastructure passes', async t => {
  const compile = await evaluateIn(t, 'settings-persistence-v1', {
    'App.jsx': 'export default function App(){ return <main><h1>Broken</h1> }',
    'styles.css': '',
  }, 4);
  assert.equal(compile.passed, false);
  assert.equal(compile.checks[0].name, 'compile-jsx');

  const fakeSave = await evaluateIn(t, 'settings-persistence-v1', {
    'App.jsx': `export default function App({initialName, initialEmail, themes}) {
      return <main><label>Display name<input defaultValue={initialName}/></label><label>Email<input defaultValue={initialEmail}/></label>
      <label>Theme<select>{themes.map(t => <option key={t.id}>{t.label}</option>)}</select></label><label>Email updates<input type="checkbox"/></label>
      <button onClick={() => document.body.insertAdjacentHTML('beforeend','<p>Saved fake Updated</p>')}>Save preferences</button><p>{initialName}</p></main>
    }`,
    'styles.css': '',
  }, 5);
  assert.equal(fakeSave.passed, false);
  assert.match(fakeSave.errors.join('\n'), /localStorage|restore|settings-save/i);

  const networkFiles = getReference('settings-persistence-v1');
  networkFiles['App.jsx'] = networkFiles['App.jsx']
    .replace("import {useMemo,useState} from 'react';", "import {useEffect,useMemo,useState} from 'react';")
    .replace('export default function App({initialName, initialEmail, themes, wantsUpdates, storageKey}) {',
      "export default function App({initialName, initialEmail, themes, wantsUpdates, storageKey}) { useEffect(() => { fetch('http://127.0.0.1:9/leak').catch(() => {}); }, []);");
  const network = await evaluateIn(t, 'settings-persistence-v1', networkFiles, 6);
  assert.equal(network.passed, false);
  assert.match(network.errors.join('\n'), /no-blocked-network-or-popups|no-console-errors|Content Security Policy|Refused/i);
});

test('student infinite loop is bounded and browser cleanup permits a later run', async t => {
  const hung = await evaluateIn(t, 'settings-persistence-v1', {
    'App.jsx': 'export default function App(){ while (true) {} }',
    'styles.css': '',
  }, 7);
  assert.equal(hung.passed, false);
  assert.match(hung.errors.join('\n'), /page-loaded|timeout/i);

  const after = await evaluateIn(t, 'keyboard-tabs-dialog-v1', getReference('keyboard-tabs-dialog-v1'), 8);
  assert.equal(after.passed, true, JSON.stringify(after.errors));
});

test('same artifact directory can be reused after incomplete or failed evaluation', async t => {
  const dir = await workspace(t);
  const artifactDir = path.join(dir, 'retryable-artifacts');
  await fs.mkdir(artifactDir, { recursive: true });
  await fs.writeFile(path.join(artifactDir, 'desktop.png'), 'partial browser output');
  await fs.writeFile(path.join(artifactDir, 'evidence.json'), '{"passed":false,"incomplete":true}');

  const compileFail = await evaluateCandidate({
    taskId: 'settings-persistence-v1',
    files: { 'App.jsx': 'export default function App(){ return <main>broken</main', 'styles.css': '' },
    seed: 9,
    browserPath,
    artifactDir,
  });

  assert.equal(compileFail.passed, false);
  assert.equal((await evidence(compileFail)).incomplete, undefined);

  const pass = await evaluateCandidate({
    taskId: 'settings-persistence-v1',
    files: getReference('settings-persistence-v1'),
    seed: 9,
    browserPath,
    artifactDir,
  });
  assert.equal(pass.passed, true, JSON.stringify(pass.errors));
  const record = await evidence(pass);
  assert.equal(record.passed, true);
  assert.equal(record.taskId, 'settings-persistence-v1');
});

test('a renderer hang inside a browser evidence read cannot trap the worker indefinitely', async t => {
  const dir = await workspace(t);
  const files = getReference('settings-persistence-v1');
  files['App.jsx'] = `const originalSet = Storage.prototype.setItem;
Storage.prototype.setItem = function(...args) {
  originalSet.apply(this, args);
  Storage.prototype.getItem = function() { while (true) {} };
};
${files['App.jsx']}`;
  const result = await evaluateCandidate({
    taskId: 'settings-persistence-v1', files, seed: 19,
    artifactDir: dir, browserPath, evaluationTimeoutMs: 1500,
  });
  assert.equal(result.passed, false);
  assert.match(result.errors.join('\n'), /evaluation-deadline/);
  const after = await evaluateIn(t, 'settings-persistence-v1', getReference('settings-persistence-v1'), 20);
  assert.equal(after.passed, true, JSON.stringify(after.errors));
});

test('partial persistence and missing keyboard behavior are not promoted', async t => {
  const partial = getReference('settings-persistence-v1');
  partial['App.jsx'] = partial['App.jsx'].replace(
    'JSON.stringify(form)', 'JSON.stringify({name:form.name,email:form.email})');
  const settings = await evaluateIn(t, 'settings-persistence-v1', partial, 31);
  assert.equal(settings.passed, false);
  assert.match(settings.errors.join('\n'), /theme|updates/i);

  const missingKey = getReference('keyboard-tabs-dialog-v1');
  missingKey['App.jsx'] = missingKey['App.jsx'].replace("if (event.key === 'Home') choose(0);", '');
  const tabs = await evaluateIn(t, 'keyboard-tabs-dialog-v1', missingKey, 32);
  assert.equal(tabs.passed, false);
  assert.match(tabs.errors.join('\n'), /Home/);
});

test('non-HTTP connection and worker capabilities are unavailable to learner code', async t => {
  const files = getReference('settings-persistence-v1');
  files['App.jsx'] = `for (const name of ['RTCPeerConnection','webkitRTCPeerConnection','WebTransport','Worker','SharedWorker']) {
    if (window[name] !== undefined) throw new Error('Unexpected browser capability: ' + name);
  }
${files['App.jsx']}`;
  const result = await evaluateIn(t, 'settings-persistence-v1', files, 44);
  assert.equal(result.passed, true, JSON.stringify(result.errors));
});
