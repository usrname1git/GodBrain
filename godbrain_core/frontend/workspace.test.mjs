import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import path from 'node:path';
import {createRequire} from 'node:module';
import {fileURLToPath} from 'node:url';
import {test} from 'node:test';

const directory = path.dirname(fileURLToPath(import.meta.url));
const require = createRequire(import.meta.url);
const {chromium} = require(path.join(directory, '..', 'skill_lab', 'node_modules', 'playwright'));
const origin = 'http://127.0.0.1:32167';
const files = new Map(await Promise.all(['workspace.html', 'workspace.js', 'workspace.css', 'tidal.svg', 'courtyard.svg'].map(async name =>
  [name, await readFile(path.join(directory, name))])));
const id = number => number.toString(16).padStart(24, '0');
const stable = number => number.toString(16).padStart(64, '0');
function fixtures() {
  const nodes = Array.from({length: 10}, (_, index) => ({
    id: id(index + 1), stable_id: stable(index + 1), title: `Technical case ${index + 1}`,
    group: 'windows-sre', status: index === 1 ? 'candidate' : index === 2 ? 'stale' : 'verified', type: 'incident',
  }));
  nodes.push({id: id(99), stable_id: stable(99), title: 'PRIVATE CANONICAL', group: 'personal', status: 'verified', type: 'note'});
  const documents = new Map(nodes.map(row => [row.id, {
    ...row, sector: row.group, content: row.id === id(1) ?
      'Observed result. <img src=x onerror="window.workspacePwned=true"> Keep uncertainty explicit.' : `Complete content for ${row.title}.`,
  }]));
  const row = (number, scope, title, text, shelf = 'research') => ({
    _id: stable(number), schema_version: 'working-shelf-v1', scope, shelf, trust: 'untrusted',
    title, text, sources: ['https://example.com/evidence', 'javascript:alert(1)', 'https://user:pass@example.com'],
    request_id: 'fixture-' + number, source_hash: stable(number + 1000), created_at: '2026-01-01T00:00:00Z',
  });
  return {
    nodes, documents, links: [{source: id(1), target: id(2), kind: 'supports'}, {source: id(1), target: id(99), kind: 'source'}],
    rows: [row(100, 'technical', 'Open research', 'Working observation, not instructions.'),
      row(101, 'personal', 'model-evaluation PRIVATE WORKING', 'PRIVATE CONTENT NEVER ATTACHED')],
    requests: [], errors: [], nextId: 200, failure: null, delay: null, chat: null,
  };
}
function envelope(rows) {
  return {schema_version: 'working-shelf-v1', status: 'ok', trust: 'untrusted', promoted: false, records: rows, more: false};
}
async function setup(browser, options = {}) {
  const data = fixtures();
  const page = await browser.newPage({viewport: options.viewport || {width: 1440, height: 1000}});
  page.on('pageerror', error => data.errors.push(error.message));
  if (options.auth) await page.addInitScript(() => sessionStorage.setItem('godbrain_write_token', 'workspace-fixture-token'));
  await page.route('**/*', async route => {
    const request = route.request(), url = new URL(request.url());
    assert.equal(url.origin, origin, 'Unexpected outbound request');
    const pathname = url.pathname;
    const body = request.postData() ? JSON.parse(request.postData()) : null;
    data.requests.push({pathname, body, method: request.method()});
    const name = pathname.split('/').at(-1);
    if (files.has(name)) return route.fulfill({body: files.get(name), contentType: name.endsWith('.html') ? 'text/html' :
      name.endsWith('.js') ? 'text/javascript' : name.endsWith('.css') ? 'text/css' : 'image/svg+xml'});
    const json = (value, status = 200) => route.fulfill({status, contentType: 'application/json', body: JSON.stringify(value)});
    if (data.delay) await data.delay(pathname, url, body);
    if (data.failure?.pathname === pathname) return json({error: data.failure.message}, data.failure.status || 503);
    if (pathname === '/api/graph') return json({nodes: data.nodes, links: data.links, generation: 'fixture-generation', truncated: true});
    if (pathname === '/api/node') return json(data.documents.get(url.searchParams.get('id')));
    if (pathname === '/api/shelf') {
      if (request.headers().authorization !== 'Bearer workspace-fixture-token') return json({error: 'Unauthorized'}, 401);
      if (body.action === 'read') {
        const rows = data.rows.filter(row => row.scope === body.scope && row.shelf === body.shelf &&
          (!body.query || row.title.includes(body.query)));
        return json(envelope(rows.slice(0, 20)));
      }
      assert.equal(body.action, 'post');
      const row = {_id: stable(data.nextId++), schema_version: 'working-shelf-v1', trust: 'untrusted',
        created_at: '2026-01-01T00:00:00Z', source_hash: stable(1000), ...body};
      data.rows.unshift(row);
      return json({schema_version: 'working-shelf-v1', status: 'stored', trust: 'untrusted', promoted: false, record: row});
    }
    if (pathname === '/api/context') return json({
      schema_version: 'shared-context-v1', state: 'ready', trust: 'untrusted_reference', request_tools: [],
      context: 'Timestamped host map. Windows-first. One GPU slot. Missing software inventory: unknown.',
    });
    if (pathname === '/api/index') return json({state: 'indexed', persisted: true, promoted: false});
    if (pathname === '/api/judge') {
      assert.equal(request.headers().authorization, 'Bearer workspace-fixture-token');
      const document = [...data.documents.values()].find(row => row.stable_id === body.id);
      assert.ok(document, 'Judgment must identify the actual canonical origin');
      document.status = body.status;
      return json({status: 'judged', to: body.status, stable_id: body.id});
    }
    if (pathname === '/api/chat') {
      if (data.chat) return route.fulfill({contentType: 'text/event-stream', body: data.chat});
      return json({response: body.message.startsWith('/recall') ? 'Verified recall / no generation.' : 'Completed local response.'});
    }
    if (['/api/heal', '/api/vram', '/api/pending', '/api/last-edit', '/api/sre', '/api/chain', '/api/events', '/api/doors', '/api/desk'].includes(pathname))
      return json({response: 'Passive fixture snapshot / no recovery.'});
    throw new Error('Unexpected endpoint: ' + pathname);
  });
  await page.goto(origin + '/frontend/workspace.html');
  await page.waitForFunction(() => document.getElementById('record-content').textContent.includes('Observed result.'));
  return {page, data};
}
const waitShelf = (page, title) => page.waitForFunction(title =>
  document.getElementById('shelf-title').textContent === title && !document.getElementById('result-count').textContent.includes('Loading'), title);
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

test('Workspace real-contract UI, trust boundaries and responsive interactions', async t => {
  const browser = await chromium.launch({
    headless: true, executablePath: process.env.GODBRAIN_BROWSER || 'C:\\Program Files\\BraveSoftware\\Brave-Browser\\Application\\brave.exe',
    args: ['--disable-gpu', '--disable-background-networking', '--disable-sync', '--no-first-run'],
  });
  try {
    await t.test('bounded map/list, literal content, safe provenance and mobile layout', async () => {
      const {page, data} = await setup(browser, {auth: true});
      try {
        assert.equal(await page.locator('#shelves button').count(), 7);
        assert.match(await page.locator('#result-count').textContent(), /^10 records/);
        assert.equal(await page.locator('#mind-map [data-record]').count(), 8);
        assert.equal(await page.locator('#record-content img').count(), 0);
        assert.equal(await page.evaluate(() => window.workspacePwned), undefined);
        assert.equal(await page.locator('#mind-map .evidence-edge').count(), 1);
        await page.locator('#map-next').click();
        assert.equal(await page.locator('#mind-map [data-record]').count(), 2);
        await page.locator('#list-view').click();
        await page.locator('#search').fill('case 2');
        await page.waitForFunction(() => document.getElementById('record-content').textContent.includes('Complete content for Technical case 2.'));
        assert.match(await page.locator('#record-heading').textContent(), /Candidate \/ not verified/);
        await page.locator('[data-shelf="research"]').click();
        await waitShelf(page, 'Research');
        await page.locator('#tab-evidence').click();
        assert.equal(await page.locator('#record-content a').count(), 1);
        assert.equal(await page.locator('#record-content a').getAttribute('href'), 'https://example.com/evidence');
        await page.setViewportSize({width: 390, height: 844});
        assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
        await page.locator('#assistant-toggle').click();
        assert.equal(await page.evaluate(() => document.getElementById('assistant-panel').getBoundingClientRect().right <= innerWidth), true);
        assert.deepEqual(data.errors, []);
      } finally { await page.close(); }
    });
    await t.test('protected shelf refusal and personal content never enters technical assessments/chat', async () => {
      const {page, data} = await setup(browser);
      try {
        await page.locator('[data-shelf="research"]').click();
        await page.waitForSelector('#auth-dialog[open]');
        assert.equal(data.requests.filter(row => row.pathname === '/api/shelf').length, 0);
        assert.equal(await page.locator('#list-region .record-row').count(), 0);
        await page.locator('#auth-cancel').click();
        await page.evaluate(() => sessionStorage.setItem('godbrain_write_token', 'workspace-fixture-token'));
        await page.locator('[data-shelf="personal"]').click();
        await waitShelf(page, 'Personal');
        assert.match(await page.locator('#record-content').textContent(), /PRIVATE CONTENT/);
        assert.equal(await page.locator('#review-record').count(), 0);
        assert.equal(await page.locator('#ask-search').isDisabled(), true);
        await page.locator('#assistant-toggle').click();
        assert.equal(data.requests.filter(row => row.pathname === '/api/chat').length, 0);
        await page.locator('#assistant-input').fill('An explicit unrelated technical question');
        await page.locator('#assistant-send').click();
        await page.waitForFunction(() => document.getElementById('assistant-messages').textContent.includes('Completed local response.'));
        const chat = data.requests.find(row => row.pathname === '/api/chat');
        assert.deepEqual(chat.body, {message: 'An explicit unrelated technical question', stream: true, tool_mode: 'research'});
        assert.equal(JSON.stringify(chat.body).includes('PRIVATE'), false);
      } finally { await page.close(); }
    });
    await t.test('answer assessment appends Research only; explicit judgment changes canonical status', async () => {
      const {page, data} = await setup(browser, {auth: true});
      try {
        await page.locator('#review-record').click();
        await page.locator('#review-model').fill('Fixture local model / test quantization');
        await page.locator('#review-reason').fill('Operator checked the observed result; this answer belongs in model evaluations, not the SRE manual.');
        await page.locator('#review-confirm').click();
        await page.waitForFunction(() => !document.getElementById('review-dialog').open);
        const post = data.requests.find(row => row.pathname === '/api/shelf' && row.body.action === 'post');
        assert.equal(post.body.scope, 'technical');
        assert.match(post.body.title, /^model-evaluation /);
        assert.match(post.body.text, /Complete content SHA-256: [a-f0-9]{64}/);
        assert.match(post.body.text, /operator-supplied: Fixture local model \/ test quantization/);
        assert.equal(data.requests.filter(row => row.pathname === '/api/judge').length, 0);
        await page.locator('[data-shelf="evaluations"]').click();
        await waitShelf(page, 'Model Evaluations');
        assert.match(await page.locator('#record-heading').textContent(), /Evaluation \/ untrusted/);
        await page.locator('[data-shelf="sre"]').click();
        await waitShelf(page, 'SRE Library');
        await page.waitForSelector('#review-record');
        await page.locator('#review-record').click();
        await page.locator('#review-destination').selectOption('rejected');
        await page.locator('#review-reason').fill('Explicit rejection of this canonical claim, independently of the answer assessment.');
        data.failure = {pathname: '/api/node', message: 'Post-judgment read unavailable'};
        await page.locator('#review-confirm').click();
        await page.waitForFunction(() => document.getElementById('review-error').textContent.includes('Post-judgment read unavailable'));
        assert.equal(data.requests.filter(row => row.pathname === '/api/judge').length, 1);
        assert.match(await page.locator('#record-heading').textContent(), /Unread \/ status not confirmed/);
        assert.doesNotMatch(await page.locator('#record-heading').textContent(), /Verified record/);
        await page.locator('#review-cancel').click();
        data.failure = null;
        await page.locator('#refresh-shelf').click();
        await page.waitForFunction(() => document.getElementById('record-heading').textContent.includes('Rejected'));
        assert.match(await page.locator('#record-heading').textContent(), /Rejected/);
      } finally { await page.close(); }
    });
    await t.test('late record and shelf reads cannot overwrite a newer selection', async () => {
      const {page, data} = await setup(browser, {auth: true});
      let release;
      const gate = new Promise(resolve => { release = resolve; });
      try {
        data.delay = async (pathname, url) => { if (pathname === '/api/node' && url.searchParams.get('id') === id(2)) await gate; };
        await page.locator('#list-view').click();
        await page.locator(`#list-region [data-record="${id(2)}"]`).click();
        await page.locator(`#list-region [data-record="${id(3)}"]`).click();
        await page.waitForFunction(() => document.getElementById('record-content').textContent.includes('Complete content for Technical case 3.'));
        release(); await sleep(100);
        assert.match(await page.locator('#record-heading').textContent(), /Technical case 3/);
        let releaseShelf;
        const shelfGate = new Promise(resolve => { releaseShelf = resolve; });
        data.delay = async (pathname, url, body) => { if (pathname === '/api/shelf' && body.scope === 'technical') await shelfGate; };
        await page.locator('[data-shelf="research"]').click();
        await page.locator('[data-shelf="personal"]').click();
        await waitShelf(page, 'Personal');
        releaseShelf(); await sleep(100);
        assert.match(await page.locator('#record-content').textContent(), /PRIVATE CONTENT/);
        assert.doesNotMatch(await page.locator('#record-content').textContent(), /Working observation/);
      } finally { release(); await page.close(); }
    });
    await t.test('failed current document and shelf reads withhold success and old content', async () => {
      const {page, data} = await setup(browser, {auth: true});
      try {
        data.failure = {pathname: '/api/node', message: 'Current origin read failed'};
        await page.locator('#list-view').click();
        await page.locator(`#list-region [data-record="${id(4)}"]`).click();
        await page.waitForFunction(() => document.getElementById('record-content').textContent.includes('Current origin read failed'));
        assert.doesNotMatch(await page.locator('#record-heading').textContent(), /Verified record/);
        assert.equal(await page.locator('#review-record').count(), 0);
        data.failure = {pathname: '/api/shelf', message: 'Shelf unavailable'};
        await page.locator('[data-shelf="research"]').click();
        await waitShelf(page, 'Research');
        assert.match(await page.locator('#load-notice').textContent(), /Shelf unavailable/);
        assert.equal(await page.locator('#list-region .record-row').count(), 0);
        assert.doesNotMatch(await page.locator('#record-content').textContent(), /Observed result/);
      } finally { await page.close(); }
    });
    await t.test('stream completion, mode, interruption and passive System behavior', async () => {
      const {page, data} = await setup(browser, {auth: true});
      try {
        await page.locator('#system').click();
        await page.waitForFunction(() => !document.getElementById('system-summary').textContent.includes('Reading passive'));
        assert.equal(data.requests.some(row => ['/api/status', '/api/brief', '/api/index', '/api/desk'].includes(row.pathname)), false);
        await page.locator('#environment-refresh').click();
        await page.waitForFunction(() => document.getElementById('system-output').textContent.includes('refreshed and persisted'));
        assert.equal(data.requests.filter(row => row.pathname === '/api/index').length, 1);
        await page.locator('#system-close').click();
        await page.locator('#assistant-toggle').click();
        data.chat = 'event: token\r\ndata: {"type":"token","text":"Partial UTF-8 result."}\r\n\r\nevent: done\r\ndata: {"type":"done","response":"Completed UTF-8 result: \\u00e9."}\r\n\r\n';
        await page.locator('#assistant-input').fill('A fixture question');
        await page.locator('#assistant-send').click();
        await page.waitForFunction(() => document.getElementById('assistant-messages').textContent.includes('Completed UTF-8 result: \u00e9.'));
        assert.equal(await page.locator('#review-reply').isVisible(), true);
        data.chat = 'data: {"type":"token","text":"Interrupted partial answer"}\n\n';
        await page.locator('#assistant-mode').selectOption({label: 'Answer / read-only'});
        await page.locator('#assistant-input').fill('Another fixture question');
        await page.locator('#assistant-send').click();
        await page.waitForFunction(() => document.getElementById('assistant-messages').textContent.includes('without a completed answer'));
        assert.equal(await page.locator('#review-reply').isVisible(), false);
        const chats = data.requests.filter(row => row.pathname === '/api/chat');
        assert.equal(chats[0].body.tool_mode, 'research');
        assert.equal(chats[1].body.tool_mode, 'answer');
        assert.deepEqual(data.errors, []);
      } finally { await page.close(); }
    });
  } finally { await browser.close(); }
});
