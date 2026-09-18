import assert from 'node:assert/strict';
import { promises as fs } from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import {
  acquireRunLock, BackendError, cannedTutorAdvice, completeLocal, hashFiles, isHostNetworkFailure, learnerMessages,
  loadState, localEndpoint, newState, parseCandidate, parseTutorAdvice, readJson, requestStop, runPractice,
  StopRequested, summarizeCheckDetail, tutorMessages, universityAppScaffold, writeJson,
} from './gym-core.mjs';
import { articleText, createDocumentationReader, documentationUrl } from './docs.mjs';
import { getTask } from './curriculum.mjs';
import { COMPETENCIES } from './competencies.mjs';
import { parseOptions, selectRetainedLesson, universityLessonPlan } from './gym.mjs';

const task = { id: 'settings', family: 'forms', title: 'Save preferences', brief: 'Save name and restore it after reload.', docs: [] };
const working = { 'App.jsx': 'export default function App(){ return <p>working</p> }', 'styles.css': '' };
const broken = { 'App.jsx': 'export default function App(){ return <p>broken</p> }', 'styles.css': '' };
const evaluatorVersion = 'runner-unit-test-v1';

test('university app scaffold satisfies static source-contract rails', () => {
  const app = universityAppScaffold('App.tsx');
  assert.match(app, /interface\s+Props/);
  assert.match(app, /useState/);
  assert.match(app, /<header\b[\s\S]*<main\b[\s\S]*<footer\b/i);
  assert.match(app, /<form\b/i);
  assert.match(app, /aria-invalid/i);
  assert.match(app, /className="menu"/);
  assert.match(app, /<nav aria-label="Primary"/);
  const capstone = universityAppScaffold('App.tsx', 'event-platform-showcase-v1');
  assert.match(capstone, /interface Props/);
  assert.match(capstone, /lifecycle/);
  const architecture = universityAppScaffold('App.tsx', 'marketing-site-architecture-v1');
  assert.match(architecture, /lifecycle/);
  assert.doesNotMatch(architecture, /props.brand \?\? "Studio"/);
  assert.equal(
    COMPETENCIES.find(item => item.id === 'persistent-settings').sourceRules.includes('form-validation'),
    false,
  );
  assert.match(capstone, /Book a demo/);
  assert.match(capstone, /aria-invalid/);
  assert.match(capstone, /className=\{menu\?'open':''\}/);
});

test('app-mode learner prompt keeps the full capstone form', () => {
  const capstone = universityAppScaffold('App.tsx', 'event-platform-showcase-v1');
  const messages = learnerMessages(
    { id: 'capstone', family: 'university', title: 'Capstone', brief: 'Keep the form.', fileMode: 'app', appFile: 'App.tsx' },
    { files: { 'App.tsx': capstone, 'styles.css': '.hero{}' } },
    '',
    '',
  );
  assert.match(messages[1].content, /Event type/);
  assert.match(messages[1].content, /Search features/);
  assert.match(messages[1].content, /Book a demo/);
  assert.doesNotMatch(messages[1].content, /\[clipped\]/);
});

test('verifier feedback strips playwright sludge and key-warning noise', () => {
  const timeout = 'locator.waitFor: Timeout 2200ms exceeded.\nCall log:\n\u001b[2m  - waiting for getByRole(\'button\', { name: /^menu$/i }).first() to be visible\u001b[22m\n';
  assert.equal(
    summarizeCheckDetail(timeout),
    "Missing getByRole('button', { name: /^menu$/i }).first()",
  );
  assert.equal(
    summarizeCheckDetail('Each child in a list should have a unique "key" prop.%s%s See https://react.dev/link/warning-keys for more information.'),
    'React list in App is missing unique key props.',
  );
  assert.ok(!summarizeCheckDetail(timeout).includes('Call log'));
  assert.ok(!summarizeCheckDetail(timeout).includes('\u001b'));
});

async function workspace(t) {
  const root = path.join(path.dirname(fileURLToPath(import.meta.url)), 'work', 'tests');
  await fs.mkdir(root, { recursive: true });
  const dir = await fs.mkdtemp(path.join(root, 'core-'));
  t.after(() => fs.rm(dir, { recursive: true, force: true }));
  return dir;
}

function options(workDir, extra = {}) {
  return { workDir, endpoint: 'http://127.0.0.1:8888/v1', maxAttempts: 2, intervalMs: 0, tutorEvery: 0, ...extra };
}

function answer(files = working, model = 'test-student') {
  return { text: JSON.stringify({ files }), model };
}

async function evaluate({ files, seed, taskId }) {
  const passed = files['App.jsx'].includes('working');
  return {
    passed, seed, taskId, evaluatorVersion,
    checks: [{ name: 'reload-persists-data', passed, detail: passed ? 'Restored value' : 'Value disappeared' }],
    errors: passed ? [] : ['Saved value did not survive reload'], artifacts: [],
  };
}

test('candidate schema rejects paths, package scripts, extra fields and malformed output', () => {
  assert.deepEqual(parseCandidate(JSON.stringify({ files: working })), working);
  assert.deepEqual(parseCandidate(`\`\`\`json\n${JSON.stringify({ files: working })}\n\`\`\``), working);
  for (const text of [
    '{"files":{"../App.jsx":"oops","styles.css":""}}',
    '{"files":{"App.jsx":"code","styles.css":"","package.json":"{}"}}',
    '{"files":{"App.jsx":"","styles.css":""}}',
    '{"files":{"App.jsx":"code","styles.css":4}}',
    '{"files":{"App.jsx":"code","styles.css":""},"passed":true}',
    'Here is some code: <button>Saved!</button>', 'null',
  ]) assert.throws(() => parseCandidate(text));
  assert.throws(() => parseCandidate(JSON.stringify({ files: { ...working, 'styles.css': '\0' } })));
  const truncatedApp = '{"files":{"App.jsx":"export default function App(){\\n  return <main>Hi</main>;\\n';
  const repairedApp = parseCandidate(truncatedApp, { fileMode: 'app', initialFiles: { 'App.jsx': '', 'styles.css': 'body{}' } });
  assert.match(repairedApp['App.jsx'], /return <main>Hi/);
  const css = ':root{--paper:#f7f4ee}.tinted{background:#e6f1ef}.dark{background:#061827}main section{padding:72px 24px}';
  const truncated = `{"files":{"styles.css":"${css} .hero{background:`;
  const repaired = parseCandidate(truncated, { fileMode: 'styles', initialFiles: working });
  assert.match(repaired['styles.css'], /main section\{padding:72px/);
  assert.doesNotMatch(repaired['styles.css'], /background:$/);
  const trailing = `${JSON.stringify({ files: { 'styles.css': css } })} trailing prose`;
  assert.equal(parseCandidate(trailing, { fileMode: 'styles', initialFiles: working })['styles.css'], css);
  assert.deepEqual(parseCandidate(JSON.stringify({ files: { 'App.jsx': working['App.jsx'] } }), {
    fileMode: 'app', initialFiles: { 'App.jsx': '', 'styles.css': 'body{}' },
  }), { 'App.jsx': working['App.jsx'], 'styles.css': 'body{}' });
  assert.deepEqual(parseCandidate(JSON.stringify({ files: { 'styles.css': '.new{}' } }), {
    fileMode: 'styles', initialFiles: working,
  }), { 'App.jsx': working['App.jsx'], 'styles.css': '.new{}' });
  assert.deepEqual(parseCandidate(JSON.stringify({ 'styles.css': '.short{}' }), {
    fileMode: 'styles', initialFiles: working,
  }), { 'App.jsx': working['App.jsx'], 'styles.css': '.short{}' });
  const typed = {
    'App.tsx': 'type AppProps={name:string};export default function App({name}:AppProps){return <p>{name}</p>}',
    'styles.css': 'p{color:#123}',
  };
  assert.deepEqual(parseCandidate(JSON.stringify({ files: typed }), { appFile: 'App.tsx' }), typed);
  assert.throws(() => parseCandidate(JSON.stringify({ files: working }), { fileMode: 'styles', initialFiles: working }));
  assert.throws(() => parseCandidate(JSON.stringify({ 'styles.css': '.new{}', 'App.jsx': 'nope' }), {
    fileMode: 'styles', initialFiles: working,
  }));
  assert.notEqual(hashFiles(working), hashFiles(broken));
});

test('styles-only prompts treat App.jsx as immutable reference and discard invalid prior output', () => {
  const messages = learnerMessages(
    { ...task, fileMode: 'styles' },
    {
      files: working,
      parseFailed: true,
      lastResponse: '{"files":{"App.jsx":"repeat this mistake"}}',
      feedback: 'Only styles.css may be written in this stage.',
    },
    '',
    '{"styles.css":".tested{}"}',
  );
  assert.match(messages[0].content, /styling an existing immutable React app/);
  assert.match(messages[0].content, /Do not return, rewrite, or describe App\.jsx/);
  assert.match(messages[0].content, /Do not invent a \.nav class/);
  assert.match(messages[0].content, /nav\{display:none\}/);
  assert.match(messages[0].content, /three distinct tones/);
  assert.match(messages[0].content, /invalid var\(\) is transparent/);
  assert.doesNotMatch(messages[0].content, /App\.jsx must default-export/);
  assert.match(messages[1].content, /Discard it completely/);
  assert.doesNotMatch(messages[1].content, /repeat this mistake/);
  assert.match(messages[1].content, /only complete replacement styles\.css/);
});

test('responsive navigation contract is explicit about typed seeded props', () => {
  const responsive = getTask('responsive-site-navigation-v1');
  assert.match(responsive.brief, /sections:Array<\{id:string,label:string\}>/);
  assert.match(responsive.brief, /proofPoints:string\[\]/);
  assert.match(responsive.brief, /never call string methods on a section object/);
  assert.match(responsive.brief, /do not hardcode fixture text/);
  assert.match(responsive.brief, /button\.menu and nav to be sibling children of header/);
  assert.match(responsive.brief, /never inline-hide nav/);
});

test('lifecycle contract is explicit about typed props and role tabs', () => {
  const lifecycle = getTask('feature-lifecycle-explorer-v1');
  assert.match(lifecycle.brief, /lifecycle:Array<\{stage:string,summary:string,features:string\[\]\}>/);
  assert.match(lifecycle.brief, /visible button or role=tab/);
  assert.match(lifecycle.brief, /across features from every lifecycle item/);
  assert.match(lifecycle.brief, /never put className="menu" on nav/);
  assert.match(lifecycle.brief, /at least 650 visible characters/);
  assert.match(lifecycle.brief, /hero, the single h1, and every content section inside the main landmark/);
  assert.match(lifecycle.brief, /do not rename props/);
});

test('app-only prompts summarize immutable CSS and discard large truncated responses', () => {
  const messages = learnerMessages(
    { ...task, fileMode: 'app', appFile: 'App.tsx' },
    {
      files: {
        'App.tsx': 'export default function App(){return <main className="shell"/>}',
        'styles.css': `.shell{display:grid}.menu{display:none}${'.discarded{color:red}'.repeat(500)}`,
      },
      parseFailed: true,
      lastResponse: `{"files":{"App.tsx":"${'truncated'.repeat(700)}"`,
      feedback: 'Model output was not valid JSON: Unterminated string.',
    },
    '',
    '',
  );
  assert.match(messages[1].content, /INCOMPLETE OR TOO LARGE/);
  assert.match(messages[1].content, /Available class names: shell, menu, discarded/);
  assert.doesNotMatch(messages[1].content, /truncatedtruncatedtruncated/);
  assert.doesNotMatch(messages[1].content, /color:red/);
  assert.ok(messages[1].content.length < 10_600);
});

test('canned tutor advice names computed tones and .nav, not new CSS variables', () => {
  const tonal = cannedTutorAdvice({
    feedback: 'professional-visual-system: The computed visual system has insufficient tonal depth.',
    files: { 'styles.css': '.tinted{background:linear-gradient(#fff,#eee)}' },
  });
  assert.match(tonal, /solid background-color/);
  assert.doesNotMatch(tonal, /Add 3-4 new tonal CSS variables/);
  const missingVars = cannedTutorAdvice({
    feedback: 'professional-visual-system: Need ≥3 distinct tones; found 0.',
    files: { 'styles.css': '.tinted{background:var(--tint)}.dark{background:var(--navy)}' },
  });
  assert.match(missingVars, /defines no :root/);
  assert.match(missingVars, /var\(--tint\)/);
  const overflow = cannedTutorAdvice({
    feedback: 'intentional-mobile-composition: Mobile composition overflows the viewport.',
    files: {
      'App.jsx': '<nav aria-label="Primary" className={menu?\'open\':\'\'}>x</nav>',
      'styles.css': '@media(max-width:640px){.nav{display:none}.nav.open{display:flex}}',
    },
  });
  assert.match(overflow, /hides \.nav but markup is <nav>/);
  const unhidden = cannedTutorAdvice({
    feedback: 'desktop-and-mobile-screenshots-without-overflow: Desktop layout overflows viewport by 67px.',
    files: {
      'App.jsx': '<nav aria-label="Primary" className={menu?\'open\':\'\'}>x</nav>',
      'styles.css': 'nav{display:flex}button.menu{display:none}',
    },
  });
  assert.match(unhidden, /Never \.nav/);
  assert.doesNotMatch(unhidden, /Replace nav\{display:none\} with \.nav/);
  const spacing = cannedTutorAdvice({
    feedback: 'professional-visual-system: Section spacing is too compressed for a premium marketing page.',
  });
  assert.match(spacing, /section padding is under 48px/);
  assert.doesNotMatch(spacing, /background tones/);
  const demoForm = cannedTutorAdvice({
    feedback: 'demo-form-validates-before-success: Missing getByRole(\'textbox\', { name: /^name$/i })',
  });
  assert.match(demoForm, /Wrapping <label>Name<input\/>/);
  assert.doesNotMatch(demoForm, /htmlFor is required/);
  const eventType = cannedTutorAdvice({
    feedback: "demo-form-validates-before-success: Missing locator('form').getByRole('combobox', { name: /event type/i })",
  });
  assert.match(eventType, /native <select>/);
  assert.doesNotMatch(eventType, /htmlFor is required/);
  const workEmail = cannedTutorAdvice({
    feedback: "demo-form-validates-before-success: Missing locator('form').getByRole('textbox', { name: /work email/i })",
  });
  assert.match(workEmail, /visible email field/);
  assert.doesNotMatch(workEmail, /htmlFor is required/);
  const searchBox = cannedTutorAdvice({
    feedback: 'feature-search-filters-seeded-content: Missing getByRole(\'textbox\', { name: /search features/i })',
  });
  assert.match(searchBox, /Search or Filter/);
  assert.doesNotMatch(searchBox, /htmlFor/);
  const truncated = cannedTutorAdvice({
    parseFailed: true,
    feedback: 'Response is not valid JSON: Unterminated string in JSON at position 6601',
  });
  assert.match(truncated, /truncated before both objects were closed/);
  const contract = cannedTutorAdvice({
    feedback: 'source-contract: CSS hides .nav but markup is <nav> without className="nav".',
  });
  assert.match(contract, /hides \.nav but markup is <nav>/);
  assert.match(contract, /nav\{display:none\}/);
});

test('known visual failures skip the GPU tutor', async t => {
  const workDir = await workspace(t);
  const roles = [];
  await runPractice(options(workDir, {
    maxAttempts: 2, tutorEvery: 1, teacherEndpoint: 'http://127.0.0.1:9999/v1',
  }), {
    tasks: [task], evaluatorVersion,
    complete: async request => {
      roles.push(request.messages[0].content.includes('frontend tutor') ? 'teacher' : 'student');
      return answer(roles.length === 1 ? broken : working);
    },
    evaluate: async request => {
      const passed = request.files['App.jsx'].includes('working');
      return {
        passed, seed: request.seed, taskId: request.taskId, evaluatorVersion,
        checks: [{ name: 'professional-visual-system', passed, detail: 'insufficient tonal depth' }],
        errors: passed ? [] : ['professional-visual-system: The computed visual system has insufficient tonal depth.'],
        artifacts: [],
      };
    },
  });
  assert.deepEqual(roles, ['student', 'student']);
  const events = (await fs.readFile(path.join(workDir, 'events.jsonl'), 'utf8'))
    .trim().split('\n').map(line => JSON.parse(line));
  const advice = events.find(item => item.type === 'tutor_advice');
  assert.equal(advice.model, 'canned-check-diagnosis');
  assert.match(advice.advice, /computed background tones/);
  assert.match(advice.advice, /var\(--tint\)/);
});

test('tutor advice is complete compact structured guidance or rejected', () => {
  assert.equal(parseTutorAdvice(JSON.stringify({
    cause: 'The state hook regex rejected a valid generic TypeScript call.',
    fixes: ['Accept optional generic parameters before the call parenthesis.', 'Add a regression fixture.'],
  })), 'CAUSE: The state hook regex rejected a valid generic TypeScript call.\n1. Accept optional generic parameters before the call parenthesis.\n2. Add a regression fixture.');
  assert.throws(() => parseTutorAdvice('3. ** [clipped]'), /incomplete or invalid JSON/);
  assert.throws(() => parseTutorAdvice(JSON.stringify({
    cause: 'x'.repeat(221),
    fixes: ['short'],
  })), /compact diagnosis limits/);
});

test('tutor sees failure first and only the writable app source', () => {
  const messages = tutorMessages(
    { ...task, fileMode: 'app', appFile: 'App.tsx' },
    {
      files: {
        'App.tsx': 'export default function App(){return <p className="plan-label">Too small</p>}',
        'styles.css': '.secret-css-marker{font-size:1px}'.repeat(500),
      },
      feedback: 'professional-visual-system: repeated text is too small',
      parseFailed: false,
    },
  );
  assert.match(messages[0].content, /styles\.css is immutable/);
  assert.match(messages[0].content, /Never recommend editing CSS or media queries/);
  assert.match(messages[0].content, /hiding \.nav instead of the nav element/);
  assert.match(messages[0].content, /too few distinct computed background tones/);
  assert.match(messages[0].content, /Do not recommend new --ink-3/);
  assert.ok(messages[1].content.indexOf('FAILURE EVIDENCE') < messages[1].content.indexOf('CURRENT APP.TSX'));
  assert.match(messages[1].content, /repeated text is too small/);
  assert.match(messages[1].content, /plan-label/);
  assert.doesNotMatch(messages[1].content, /secret-css-marker/);
  assert.doesNotMatch(messages[1].content, /\[clipped\]/);
});

test('only credential-free literal loopback model endpoints are allowed', () => {
  assert.equal(localEndpoint('http://127.0.0.1:8888/v1/'), 'http://127.0.0.1:8888/v1');
  assert.equal(localEndpoint('http://[::1]:8888/v1'), 'http://[::1]:8888/v1');
  for (const url of [
    'https://api.example.com/v1', 'http://localhost.evil.example/v1',
    'http://user:secret@127.0.0.1/v1', 'http://127.0.0.1/v1?token=secret',
    'file:///tmp/model', 'not-a-url',
  ]) assert.throws(() => localEndpoint(url));
});

test('official documentation is reference-only and offline absence is explicit', async t => {
  const workDir = await workspace(t);
  assert.equal(documentationUrl('https://react.dev/learn#state'), 'https://react.dev/learn');
  assert.equal(documentationUrl('https://www.typescriptlang.org/docs/handbook/jsx.html'),
    'https://www.typescriptlang.org/docs/handbook/jsx.html');
  assert.throws(() => documentationUrl('http://react.dev/learn'));
  assert.throws(() => documentationUrl('https://react.dev.evil.example/learn'));
  assert.equal(articleText('<nav>menu</nav><main><script>steal()</script><p>State &amp; props</p></main>'), 'State & props');
  const result = await createDocumentationReader(workDir, { offline: true })({
    ...task, docs: [{ url: 'https://react.dev/learn' }],
  }, new AbortController().signal);
  assert.equal(result.text, '');
  assert.equal(result.warnings.length, 1);
});

test('one worker owns the lock and a closed worker needs no manual stale-lock removal', async t => {
  const workDir = await workspace(t);
  const release = await acquireRunLock(workDir);
  try {
    await assert.rejects(acquireRunLock(workDir), /Another gym worker/);
  } finally {
    release();
  }
  const releaseAgain = await acquireRunLock(workDir);
  releaseAgain();
});

test('a failed attempt gets actual feedback and only two passing variants produce a lesson', async t => {
  const workDir = await workspace(t);
  const prompts = [];
  const seeds = [];
  const state = await runPractice(options(workDir), {
    tasks: [task], evaluatorVersion,
    complete: async request => {
      prompts.push(request.messages);
      return answer(prompts.length === 1 ? broken : working);
    },
    evaluate: async request => { seeds.push(request.seed); return evaluate(request); },
  });
  assert.equal(state.stats.attempts, 2);
  assert.equal(state.stats.failed, 1);
  assert.equal(state.stats.passed, 1);
  assert.equal(state.lessons.length, 1);
  assert.equal(state.lessons[0].sourceHash, hashFiles(working));
  assert.match(prompts[1][1].content, /did not survive reload/);
  assert.notEqual(seeds.at(-1), seeds.at(-2));
  const receipt = await readJson(path.join(workDir, 'runs', state.lessons[0].runId, 'receipt.json'));
  assert.equal(receipt.evidence.length, 2);
  assert.equal(receipt.hostAuthority, false);
  assert.equal(receipt.weightsUpdated, false);
});

test('passing practice but failing transfer cannot qualify a reusable example', async t => {
  const workDir = await workspace(t);
  let calls = 0;
  const state = await runPractice(options(workDir, { maxAttempts: 1 }), {
    tasks: [task], evaluatorVersion, complete: async () => answer(),
    evaluate: async request => {
      const result = await evaluate(request);
      if (++calls === 2) return { ...result, passed: false, checks: [{ name: 'transfer', passed: false }], errors: ['Hardcoded sample'] };
      return result;
    },
  });
  assert.equal(state.stats.failed, 1);
  assert.equal(state.lessons.length, 0);
});

test('parser errors are recoverable practice failures, not a reason to ask the operator', async t => {
  const workDir = await workspace(t);
  let calls = 0;
  const state = await runPractice(options(workDir), {
    tasks: [task], evaluatorVersion, evaluate,
    complete: async request => {
      if (++calls === 1) return { text: 'not JSON', model: 'test-student' };
      assert.match(request.messages[1].content, /not valid JSON/);
      assert.match(request.messages[1].content, /YOUR LAST RESPONSE/);
      assert.match(request.messages[1].content, /not JSON/);
      return answer();
    },
  });

  assert.equal(state.stats.failed, 1);
  assert.equal(state.stats.passed, 1);
});

test('learner feedback describes seeded contracts without leaking fixture strings', async t => {
  const workDir = await workspace(t);
  let calls = 0;
  const seededText = 'Configurable registration and communication workflows';
  const state = await runPractice(options(workDir), {
    tasks: [task], evaluatorVersion,
    complete: async request => {
      calls++;
      if (calls === 2) {
        assert.match(request.messages[1].content, /seeded proofPoints from props/);
        assert.doesNotMatch(request.messages[1].content, new RegExp(seededText));
      }
      return answer(calls === 1 ? broken : working);
    },
    evaluate: async request => {
      const passed = request.files['App.jsx'].includes('working');
      return {
        passed, seed: request.seed, taskId: request.taskId, evaluatorVersion,
        checks: [{
          name: passed ? 'working' : 'honest-substantial-content',
          passed,
          detail: passed ? 'working' : `No visible text found: ${seededText}`,
        }],
        errors: passed ? [] : [`honest-substantial-content: No visible text found: ${seededText}`],
        artifacts: [],
      };
    },
  });
  assert.equal(state.stats.failed, 1);
  assert.equal(state.stats.passed, 1);
});

test('learner feedback preserves exact non-seeded visual diagnostics', async t => {
  const workDir = await workspace(t);
  let calls = 0;
  const detail = 'The typography lacks a deliberate hierarchy.';
  const state = await runPractice(options(workDir), {
    tasks: [task], evaluatorVersion,
    complete: async request => {
      calls++;
      if (calls === 2) assert.match(request.messages[1].content, new RegExp(detail));
      return answer(calls === 1 ? broken : working);
    },
    evaluate: async request => {
      const passed = request.files['App.jsx'].includes('working');
      return {
        passed, seed: request.seed, taskId: request.taskId, evaluatorVersion,
        checks: [{ name: 'professional-visual-system', passed, detail }],
        errors: passed ? [] : [`professional-visual-system: ${detail}`],
        artifacts: [],
      };
    },
  });
  assert.equal(state.stats.failed, 1);
  assert.equal(state.stats.passed, 1);
});

test('a complete source with only missing outer JSON braces is repaired before evaluation', async t => {
  const workDir = await workspace(t);
  let calls = 0;
  const state = await runPractice(options(workDir, { maxAttempts: 1 }), {
    tasks: [task], evaluatorVersion, evaluate,
    complete: async () => {
      calls++;
      return { text: answer().text.slice(0, -1), model: 'test-student' };
    },
  });
  assert.equal(calls, 1);
  assert.equal(state.stats.failed, 0);
  assert.equal(state.stats.passed, 1);
});

test('a retained university lesson is revalidated without another model generation', async t => {
  const workDir = await workspace(t);
  let generations = 0;
  const state = await runPractice(options(workDir, { maxAttempts: 1 }), {
    tasks: [{ ...task, initialFiles: working, revalidateInitial: true }],
    evaluatorVersion,
    evaluate,
    complete: async () => {
      generations++;
      return answer();
    },
  });
  assert.equal(generations, 0);
  assert.equal(state.stats.passed, 1);
  const receipt = await readJson(path.join(workDir, 'runs', state.lastRun.runId, 'receipt.json'));
  assert.equal(receipt.finishReason, 'revalidate');
  assert.equal(receipt.model, 'retained-lesson');
});

test('an evaluator change revalidates the saved candidate before generating again', async t => {
  const workDir = await workspace(t);
  const initial = newState();
  initial.evaluatorVersion = 'browser-old';
  initial.active = {
    taskId: task.id,
    attempt: 2,
    files: working,
    feedback: 'obsolete evaluator failure',
    advice: 'obsolete advice',
    trainSeed: 17,
    holdoutSeed: 19,
    customTask: { ...task, fileMode: 'app' },
  };
  await writeJson(path.join(workDir, 'state.json'), initial);
  let generations = 0;
  const state = await runPractice(options(workDir, { maxAttempts: 1 }), {
    tasks: [task],
    evaluatorVersion,
    evaluate,
    complete: async () => {
      generations++;
      throw new Error('The learner must not run before evaluator-change revalidation.');
    },
  });
  const receipt = await readJson(path.join(workDir, 'runs', state.lastRun.runId, 'receipt.json'));
  assert.equal(generations, 0);
  assert.equal(state.lastRun.passed, true);
  assert.equal(receipt.model, 'retained-lesson');
  assert.equal(receipt.finishReason, 'revalidate');
});

test('autoplay off waits after evaluate instead of starting the next generate', async t => {
  const workDir = await workspace(t);
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(new StopRequested('stop after one')), 800);
  let completes = 0;
  await runPractice(options(workDir, {
    continuous: true, intervalMs: 0, tutorEvery: 0, externalSignal: controller.signal,
    autoplayEnabled: async () => false,
  }), {
    tasks: [task], evaluatorVersion,
    complete: async () => { completes += 1; return answer(working); },
    evaluate,
  });
  clearTimeout(timer);
  assert.equal(completes, 1);
  const state = JSON.parse(await fs.readFile(path.join(workDir, 'state.json'), 'utf8'));
  assert.equal(state.status, 'stopped');
});

test('tutor and student take serial turns and tutor prose is not a verdict', async t => {
  const workDir = await workspace(t);
  const roles = [];
  const state = await runPractice(options(workDir, {
    tutorEvery: 1, teacherEndpoint: 'http://127.0.0.1:9999/v1',
  }), {
    tasks: [task], evaluatorVersion, evaluate,
    complete: async request => {
      if (request.endpoint.includes(':9999')) {
        roles.push('teacher');
        assert.match(request.messages[0].content, /do not speculate that required prop data was absent/);
        assert.match(request.messages[0].content, /Return only compact JSON/);
        return {
          text: JSON.stringify({
            cause: 'The failed source did not persist the input state.',
            fixes: ['Persist the controlled value before reporting success.'],
          }),
          model: 'test-teacher',
        };
      }
      roles.push('student');
      return answer(roles.length === 1 ? broken : working);
    },
  });
  assert.deepEqual(roles, ['student', 'teacher', 'student']);
  assert.equal(state.stats.attempts, 2);
  assert.equal(state.stats.passed, 1);
  assert.equal(state.lessons[0].model, 'test-student');
});

test('durable tested examples are automatically shared with a later model', async t => {
  const workDir = await workspace(t);
  await runPractice(options(workDir), { tasks: [task], evaluatorVersion, evaluate, complete: async () => answer(working, 'teacher-A') });
  const state = await runPractice(options(workDir), {
    tasks: [task], evaluatorVersion, evaluate,
    complete: async request => {
      assert.match(request.messages[1].content, /teacher-A/);
      assert.match(request.messages[1].content, /scoped working example/);
      return answer(working, 'student-B');
    },
  });
  assert.equal(state.stats.attempts, 2);
  assert.equal(state.lessons[0].model, 'student-B');
  assert.equal(state.stats.byTask.settings.passed, 2);
});

test('up to three distinct passing implementations are retained per task', async t => {
  const workDir = await workspace(t);
  const variants = ['alpha', 'beta', 'gamma', 'delta'].map(name => ({
    'App.jsx': `export default function App(){ return <p>working ${name}</p> }`,
    'styles.css': '',
  }));
  for (const files of variants) {
    await runPractice(options(workDir, { maxAttempts: 1 }), {
      tasks: [task], evaluatorVersion, evaluate, complete: async () => answer(files),
    });
  }
  const state = await loadState(workDir);
  const retained = state.lessons.filter(item => item.taskId === task.id);
  assert.equal(retained.length, 3);
  assert.deepEqual(retained.map(item => item.sourceHash), variants.slice(1).map(hashFiles));
});

test('refreshing a retained implementation preserves its rotation slot', async t => {
  const workDir = await workspace(t);
  const alpha = {
    'App.jsx': 'export default function App(){ return <p>working alpha</p> }',
    'styles.css': '',
  };
  const beta = {
    'App.jsx': 'export default function App(){ return <p>working beta</p> }',
    'styles.css': '',
  };
  for (const files of [alpha, beta, alpha]) {
    await runPractice(options(workDir, { maxAttempts: 1 }), {
      tasks: [task], evaluatorVersion, evaluate, complete: async () => answer(files),
    });
  }
  const state = await loadState(workDir);
  const retained = state.lessons.filter(item => item.taskId === task.id);
  assert.deepEqual(retained.map(item => item.sourceHash), [hashFiles(alpha), hashFiles(beta)]);
  assert.equal(retained[0].runId, state.recent.at(-1));
});

test('retained implementations alternate deterministically by selection count', () => {
  const lessons = [
    { taskId: task.id, evaluatorVersion, sourceHash: 'alpha', stale: false },
    { taskId: task.id, evaluatorVersion, sourceHash: 'beta', stale: false },
  ];
  assert.deepEqual(
    [0, 1, 2, 3].map(count =>
      selectRetainedLesson(lessons, task.id, evaluatorVersion, count)?.sourceHash),
    ['alpha', 'beta', 'alpha', 'beta'],
  );
});

test('a prior-evaluator lesson is selected only as a revalidation candidate', () => {
  const lessons = [
    { taskId: task.id, evaluatorVersion: 'browser-v1', sourceHash: 'alpha', stale: false },
    { taskId: task.id, evaluatorVersion: 'browser-v1', sourceHash: 'beta', stale: false },
  ];
  assert.equal(selectRetainedLesson(lessons, task.id, 'browser-v2', 0), null);
  assert.equal(
    selectRetainedLesson(lessons, task.id, 'browser-v2', 1, true)?.sourceHash,
    'beta',
  );
});

test('a later failure of the same implementation makes that lesson stale', async t => {
  const workDir = await workspace(t);
  await runPractice(options(workDir), { tasks: [task], evaluatorVersion, evaluate, complete: async () => answer() });
  const state = await runPractice(options(workDir, { maxAttempts: 1 }), {
    tasks: [task], evaluatorVersion, complete: async () => answer(),
    evaluate: async request => ({ ...(await evaluate(request)), passed: false, checks: [{ name: 'regression', passed: false }] }),
  });
  assert.equal(state.lessons[0].stale, true);
});

test('stop cancels a pending model request and the next invocation resumes the exercise', async t => {
  const workDir = await workspace(t);
  const stopped = await runPractice(options(workDir, { continuous: true }), {
    tasks: [task], evaluatorVersion, evaluate,
    complete: async ({ signal }) => {
      await requestStop(workDir);
      return new Promise((resolve, reject) => {
        signal.addEventListener('abort', () => reject(signal.reason), { once: true });
      });
    },
  });
  assert.equal(stopped.status, 'stopped');
  assert.equal(stopped.active.taskId, task.id);
  assert.equal(stopped.stats.attempts, 0);
  const resumed = await runPractice(options(workDir), { tasks: [task], evaluatorVersion, evaluate, complete: async () => answer() });
  assert.equal(resumed.status, 'idle');
  assert.equal(resumed.stats.passed, 1);
});

test('bad evaluator output fails closed and a backend outage is not a failed exercise', async t => {
  const workDir = await workspace(t);
  await assert.rejects(runPractice(options(workDir), {
    tasks: [task], evaluatorVersion, complete: async () => answer(),
    evaluate: async () => ({ passed: true, checks: [] }),
  }), /invalid verdict/);
  assert.equal((await loadState(workDir)).lessons.length, 0);
  await assert.rejects(runPractice(options(workDir), {
    tasks: [task], evaluatorVersion, evaluate,
    complete: async () => { throw new BackendError('server unavailable'); },
  }), /server unavailable/);
  const state = await loadState(workDir);
  assert.equal(state.stats.failed, 0);
  assert.equal(state.stats.infrastructureErrors, 1);
});

test('model transport uses the local OpenAI route with thinking off and no tool permissions', async t => {
  let requestBody;
  const server = http.createServer(async (request, response) => {
    response.setHeader('Content-Type', 'application/json');
    if (request.url === '/v1/models') {
      response.end(JSON.stringify({ data: [{ id: 'offline-model' }] }));
      return;
    }
    const chunks = [];
    for await (const chunk of request) chunks.push(chunk);
    requestBody = JSON.parse(Buffer.concat(chunks).toString());
    response.end(JSON.stringify({ choices: [{ message: { content: JSON.stringify({ files: working }) }, finish_reason: 'stop' }] }));
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => { server.closeAllConnections(); server.close(); });
  const result = await completeLocal({
    endpoint: `http://127.0.0.1:${server.address().port}/v1`,
    messages: [{ role: 'user', content: 'synthetic exercise' }],
  });
  assert.equal(result.model, 'offline-model');
  assert.equal(requestBody.chat_template_kwargs.enable_thinking, false);
  assert.equal(requestBody.cache_prompt, false);
  assert.equal(requestBody.stream, true);
  assert.equal(requestBody.tools, undefined);
});

test('host socket exhaustion retries without grading the candidate', async t => {
  const workDir = await workspace(t);
  const controller = new AbortController();
  let modelCalls = 0;
  let browserCalls = 0;
  const state = await runPractice(options(workDir, {
    continuous: true, retryMs: 1, externalSignal: controller.signal,
    onProgress: () => controller.abort(new StopRequested('Test completed one exercise.')),
  }), {
    tasks: [task], evaluatorVersion,
    complete: async () => { modelCalls++; return answer(); },
    evaluate: async request => {
      if (++browserCalls === 1) {
        return {
          passed: false, seed: request.seed, taskId: request.taskId, evaluatorVersion,
          checks: [
            { name: 'app-rendered-visible-content', passed: false, detail: "Missing locator('#root')" },
            { name: 'no-console-errors', passed: false, detail: 'Failed to load resource: net::ERR_NO_BUFFER_SPACE' },
          ],
          errors: [
            "app-rendered-visible-content: Missing locator('#root')",
            'no-console-errors: Failed to load resource: net::ERR_NO_BUFFER_SPACE',
          ],
          artifacts: [],
        };
      }
      return evaluate(request);
    },
  });
  assert.equal(isHostNetworkFailure('net::ERR_NO_BUFFER_SPACE'), true);
  assert.equal(modelCalls, 1);
  assert.equal(browserCalls, 3);
  assert.equal(state.stats.infrastructureErrors, 1);
  assert.equal(state.stats.failed, 0);
  assert.equal(state.stats.passed, 1);
});

test('a transient browser outage retries the same candidate without grading it as a failure', async t => {
  const workDir = await workspace(t);
  const controller = new AbortController();
  let modelCalls = 0;
  let browserCalls = 0;
  const state = await runPractice(options(workDir, {
    continuous: true, retryMs: 1, externalSignal: controller.signal,
    onProgress: () => controller.abort(new StopRequested('Test completed one exercise.')),
  }), {
    tasks: [task], evaluatorVersion,
    complete: async () => { modelCalls++; return answer(); },
    evaluate: async request => {
      if (++browserCalls === 1) throw new Error('Browser launch temporarily unavailable');
      return evaluate(request);
    },
  });
  assert.equal(modelCalls, 1);
  assert.equal(browserCalls, 3);
  assert.equal(state.stats.infrastructureErrors, 1);
  assert.equal(state.stats.failed, 0);
  assert.equal(state.stats.passed, 1);
  assert.equal(state.status, 'stopped');
});

test('university lesson plan harvests only after two current-evaluator sources', () => {
  const lessons = [
    { taskId: 'cap-v28', runId: 'a', sourceHash: '1', evaluatorVersion: 'old', stale: false },
    { taskId: 'cap-v28', runId: 'b', sourceHash: '2', evaluatorVersion: 'now', stale: false },
  ];
  const bump = universityLessonPlan({
    lessons, taskId: 'cap-v28', evaluatorVersion: 'now', revalidateLesson: false,
  });
  assert.equal(bump.revalidate, false);
  assert.equal(bump.landScaffold, false);
  const firstNight = universityLessonPlan({
    lessons: lessons.filter(item => item.evaluatorVersion === 'old'),
    taskId: 'cap-v28', evaluatorVersion: 'now', revalidateLesson: false,
  });
  assert.equal(firstNight.revalidate, true);
  assert.equal(firstNight.lesson.evaluatorVersion, 'old');
  const harvest = universityLessonPlan({
    lessons: [
      ...lessons,
      { taskId: 'cap-v28', runId: 'c', sourceHash: '3', evaluatorVersion: 'now', stale: false },
    ],
    taskId: 'cap-v28', evaluatorVersion: 'now', revalidateLesson: true,
  });
  assert.equal(harvest.revalidate, true);
  const freshStudio = universityLessonPlan({
    lessons: [], taskId: 'cap-v29', evaluatorVersion: 'now',
  });
  assert.equal(freshStudio.landScaffold, true);
  assert.equal(freshStudio.revalidate, false);
});

test('CLI rejects malformed numeric controls and model prompts stay bounded', () => {
  assert.equal(parseOptions(['run', '--continuous']).values.continuous, true);
  assert.throws(() => parseOptions(['run', '--rounds', '-1']));
  assert.throws(() => parseOptions(['run', '--rounds', '2.5']));
  assert.throws(() => parseOptions(['run', 'extra']));
  const prompt = learnerMessages(task, { files: working, feedback: 'x'.repeat(20_000) }, 'd'.repeat(20_000), 'l'.repeat(20_000));
  assert.ok(prompt[1].content.length < 13_100);
  assert.match(prompt[0].content, /cannot edit tests/);
});

test('OpenAI event streams preserve content across chunk boundaries', async t => {
  const files = { ...working, 'styles.css': '/* caf\u00e9 */' };
  const content = JSON.stringify({ files });
  const server = http.createServer((request, response) => {
    response.writeHead(200, { 'Content-Type': 'text/event-stream' });
    const body = Buffer.from([
      ': keepalive\n\n',
      `data: ${JSON.stringify({ choices: [{ delta: { content: content.slice(0, 21) }, finish_reason: null }] })}\n\n`,
      `data: ${JSON.stringify({ choices: [{ delta: { content: content.slice(21) }, finish_reason: 'stop' }] })}\r\n\r\n`,
      'data: [DONE]\n\n',
    ].join(''));
    for (let offset = 0; offset < body.length; offset += 7) response.write(body.subarray(offset, offset + 7));
    response.end();
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => { server.closeAllConnections(); server.close(); });
  const result = await completeLocal({
    endpoint: `http://127.0.0.1:${server.address().port}/v1`, model: 'stream-model',
    messages: [{ role: 'user', content: 'synthetic fixture' }],
  });
  assert.deepEqual(parseCandidate(result.text), files);
  assert.equal(result.finishReason, 'stop');
});

test('stopping disconnects an active completion stream', { timeout: 5000 }, async t => {
  const controller = new AbortController();
  let closed;
  const disconnected = new Promise(resolve => { closed = resolve; });
  const server = http.createServer((request, response) => {
    response.writeHead(200, { 'Content-Type': 'text/event-stream' });
    response.write('data: {"choices":[{"delta":{"content":"partial"},"finish_reason":null}]}\n\n');
    response.once('close', closed);
    setTimeout(() => controller.abort(new StopRequested('cancel live stream')), 30);
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => { server.closeAllConnections(); server.close(); });
  await assert.rejects(completeLocal({
    endpoint: `http://127.0.0.1:${server.address().port}/v1`, model: 'stream-model',
    messages: [{ role: 'user', content: 'synthetic fixture' }], signal: controller.signal,
  }), /cancel live stream/);
  await disconnected;
});

test('a disconnected stream without a finish marker is not a successful model response', async t => {
  const server = http.createServer((request, response) => {
    response.writeHead(200, { 'Content-Type': 'text/event-stream' });
    response.end(`data: ${JSON.stringify({ choices: [{ delta: { content: answer().text } }] })}\n\n`);
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => { server.closeAllConnections(); server.close(); });
  await assert.rejects(completeLocal({
    endpoint: `http://127.0.0.1:${server.address().port}/v1`, model: 'stream-model',
    messages: [{ role: 'user', content: 'synthetic fixture' }],
  }), /without a completion marker/);
});
