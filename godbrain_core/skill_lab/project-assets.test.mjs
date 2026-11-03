import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { promises as fs } from 'node:fs';
import { existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { deflateSync } from 'node:zlib';
import test from 'node:test';
import { chromium } from 'playwright';
import { loadProjectCatalog, projectAssetRequest, projectIds } from './project-assets.mjs';
import { evaluateProjectCandidate } from './project-browser.mjs';
import { exportProjectSite } from './export-project-site.mjs';
import { startDashboard } from './dashboard.mjs';
import { createCampaign, advanceCampaigns, requestCampaignAlternatives } from './coach.mjs';
import { claimObjective, completeObjective, enqueueObjective, listObjectives } from './objectives.mjs';
import { hashFiles, writeJson } from './gym-core.mjs';

const root = path.dirname(fileURLToPath(import.meta.url));
const browserPath = process.env.GODBRAIN_BROWSER ?? [
  'C:\\Program Files\\BraveSoftware\\Brave-Browser\\Application\\brave.exe',
  path.join(process.env['ProgramFiles(x86)'] ?? 'C:\\Program Files (x86)', 'Microsoft', 'Edge', 'Application', 'msedge.exe'),
  path.join(process.env.ProgramFiles ?? 'C:\\Program Files', 'Google', 'Chrome', 'Application', 'chrome.exe'),
].find(candidate => existsSync(candidate));
const digest = value => createHash('sha256').update(value).digest('hex');
const runId = '00000001-aaaaaaaaaaaa';
const files = {
  'App.jsx': `export default function App({projects}) { return <main><h1>Project showcase</h1>
    <p>These curated source screenshots illustrate selected projects. Static previews do not assert current host readiness or grant any runtime authority.</p>
    {projects.map(p=><article key={p.id}><h2>{p.title}</h2><p>{p.description}</p>{p.images.map(i=><img key={i.id} src={i.url} width={i.width} height={i.height} alt={i.description}/>)}</article>)}</main> }`,
  'styles.css': 'body{margin:0;background:#101820;color:#eee;font:18px sans-serif}main{padding:24px;max-width:1000px;margin:auto}img{display:block;width:100%;max-width:320px;height:auto}',
};
const task = { title: 'Source showcase', objectiveMode: 'explore', retainLesson: false, clientProjectIds: ['alpha'] };

function png(red) {
  const chunk = (type, data) => {
    const payload = Buffer.concat([Buffer.from(type), data]);
    let crc = 0xffffffff;
    for (const byte of payload) {
      crc ^= byte;
      for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0);
    }
    const length = Buffer.alloc(4), checksum = Buffer.alloc(4);
    length.writeUInt32BE(data.length); checksum.writeUInt32BE((crc ^ 0xffffffff) >>> 0);
    return Buffer.concat([length, payload, checksum]);
  };
  const header = Buffer.alloc(13);
  header.writeUInt32BE(2, 0); header.writeUInt32BE(2, 4); header[8] = 8; header[9] = 6;
  const row = [0, red, 64, 255 - red, 255, red, 64, 255 - red, 255];
  return Buffer.concat([Buffer.from('89504e470d0a1a0a', 'hex'), chunk('IHDR', header),
    chunk('IDAT', deflateSync(Buffer.from([...row, ...row]))), chunk('IEND', Buffer.alloc(0))]);
}

async function workspace(t) {
  const parent = path.join(root, 'work', 'tests');
  await fs.mkdir(parent, { recursive: true });
  const dir = await fs.mkdtemp(path.join(parent, 'project-assets-'));
  t.after(() => fs.rm(dir, { recursive: true, force: true }));
  return dir;
}

async function fixture(workDir, red = 220) {
  const projects = [];
  for (const id of ['alpha', 'bravo']) {
    const bytes = png(id === 'alpha' ? red : 30);
    await fs.mkdir(path.join(workDir, 'showcase', 'assets', id), { recursive: true });
    await fs.writeFile(path.join(workDir, 'showcase', 'assets', id, 'COVER.png'), bytes);
    projects.push({
      id, title: `${id} project`, description: 'Curated public source UI preview, not a live readiness certificate.',
      url: 'https://example.org/projects/', source_url: 'https://github.com/example/project',
      cover: 'COVER', images: [{
        id: 'COVER', path: `assets/${id}/COVER.png`, sha256: digest(bytes), width: 2, height: 2,
        description: `${id} source view`, capture_kind: 'synthetic-test',
      }],
    });
  }
  const catalog = { schema_version: 1, projects };
  await writeJson(path.join(workDir, 'showcase', 'catalog.json'), catalog);
  return catalog;
}

async function receipt(workDir) {
  await fs.mkdir(path.join(workDir, 'runs', runId), { recursive: true });
  await writeJson(path.join(workDir, 'runs', runId, 'source.json'), files);
  await writeJson(path.join(workDir, 'runs', runId, 'receipt.json'), {
    passed: true, objectiveMode: 'explore', taskId: 'image-client', sourceHash: hashFiles(files),
    clientProjectIds: ['alpha'], clientAssetProfile: 'client-project-assets-v1', seeds: [1, 2],
  });
}

test('curated catalogs bind raster bytes and expose only exactly selected versioned images', async t => {
  const workDir = await workspace(t);
  const input = await fixture(workDir);
  const catalog = await loadProjectCatalog(workDir, ['alpha']);
  assert.deepEqual(catalog.projects.map(p => p.id), ['alpha']);
  assert.equal(catalog.assets.size, 1);
  const url = catalog.projects[0].images[0].url.slice(1);
  assert.ok(projectAssetRequest(catalog, url));
  for (const bad of [url.split('?')[0], `${url}&extra=1`, url.replace('alpha', 'bravo'), `/../${url}`, `${url}#x`]) {
    assert.equal(projectAssetRequest(catalog, bad), null);
  }
  await fs.writeFile(path.join(workDir, 'showcase', input.projects[0].images[0].path), png(20));
  await assert.rejects(loadProjectCatalog(workDir, ['alpha']), /hash mismatch/);
});

test('catalog admission rejects malformed dimensions, paths, selections, private links and junctions', async t => {
  const workDir = await workspace(t);
  const original = await fixture(workDir);
  for (const change of [
    c => { c.projects[0].images[0].path = '../outside.png'; },
    c => { c.projects[0].images[0].width = 9000; },
    c => { c.projects[0].cover = 'MISSING'; },
    c => { c.projects[0].url = 'https://127.1/'; },
    c => { c.projects[0].url = 'https://panel.localhost./'; },
    c => { c.projects[0].url = 'https://user:secret@example.org/'; },
    c => { c.projects[0].url = 'https://example.org/?token=synthetic'; },
    c => { c.projects[0].extra = 'Unsupported public metadata'; },
  ]) {
    const input = structuredClone(original); change(input);
    await writeJson(path.join(workDir, 'showcase', 'catalog.json'), input);
    await assert.rejects(loadProjectCatalog(workDir), Error);
  }
  await writeJson(path.join(workDir, 'showcase', 'catalog.json'), original);
  await assert.rejects(loadProjectCatalog(workDir, ['missing']), /missing/);
  for (const ids of [['alpha', 'alpha'], ['../alpha'], 'alpha']) assert.throws(() => projectIds(ids), /selection/);
  const absent = path.join(workDir, 'absent');
  assert.equal(await loadProjectCatalog(absent), null);
  await assert.rejects(loadProjectCatalog(absent, ['alpha']), /ENOENT/);
  const real = path.join(workDir, 'real-alpha');
  await fs.rename(path.join(workDir, 'showcase', 'assets', 'alpha'), real);
  await fs.symlink(real, path.join(workDir, 'showcase', 'assets', 'alpha'), process.platform === 'win32' ? 'junction' : 'dir');
  await assert.rejects(loadProjectCatalog(workDir), /links or junctions/);
});

test('manual project selection survives shell, polish and alternatives without course qualification', async t => {
  const workDir = await workspace(t);
  await fixture(workDir);
  const campaign = await createCampaign(workDir, {
    name: 'Image portfolio', siteType: 'portfolio', brief: 'Show these curated projects.', projectIds: ['alpha'],
  }, []);
  let objective = await claimObjective(workDir, []);
  assert.deepEqual(objective.clientProjectIds, ['alpha']);
  assert.equal(objective.retainLesson, false);
  assert.match(objective.brief, /projects/);
  await receipt(workDir);
  await completeObjective(workDir, objective.objectiveId, { runId }, 'passed');
  await advanceCampaigns(workDir, []);
  objective = await claimObjective(workDir, []);
  assert.deepEqual(objective.clientProjectIds, ['alpha']);
  await completeObjective(workDir, objective.objectiveId, { runId }, 'passed');
  await advanceCampaigns(workDir, []);
  await requestCampaignAlternatives(workDir, campaign.id, []);
  const alternatives = (await listObjectives(workDir)).filter(item => item.campaignStage?.startsWith('alternative'));
  assert.equal(alternatives.length, 4);
  assert.ok(alternatives.every(item => item.mode === 'explore' && item.clientProjectIds.join() === 'alpha'));
  await assert.rejects(enqueueObjective(workDir, {
    mode: 'qualify', title: 'Cannot qualify images', prompt: 'Use images', contractTaskId: 'trusted',
  }, [{ id: 'trusted', title: 'Trusted', brief: 'Trusted', family: 'x' }], { clientProjectIds: ['alpha'] }), /qualif/i);
  const queuePath = path.join(workDir, 'objectives.json');
  const queue = JSON.parse(await fs.readFile(queuePath, 'utf8'));
  const queued = queue.items.find(item => item.status === 'queued');
  queued.mode = 'qualify'; queued.contractTaskId = 'trusted';
  await writeJson(queuePath, queue);
  await assert.rejects(claimObjective(workDir, [{ id: 'trusted', title: 'Trusted', brief: 'Trusted', family: 'x' }]), /cannot qualify/);
});

test('saved previews reload replaced image bytes and props without queuing a model request', async t => {
  const workDir = await workspace(t);
  await fixture(workDir);
  await receipt(workDir);
  const server = await startDashboard({ workDir, tasks: [], port: 0 });
  t.after(() => server.close());
  const base = server.origin;
  const browser = await chromium.launch({
    executablePath: browserPath,
    headless: true, chromiumSandbox: true, args: ['--disable-gpu', '--disable-extensions'],
  });
  t.after(() => browser.close());
  const page = await browser.newPage();
  await page.goto(`${base}/preview/${runId}/`);
  const image = page.locator('img').first();
  await image.evaluate(img => img.decode());
  const oldPixels = await image.screenshot();
  const before = await fs.readFile(path.join(workDir, 'runs', runId, 'source.json'), 'utf8');
  const propsUrl = `${base}/preview/${runId}/props.js`;
  const oldProps = await (await fetch(propsUrl)).text();
  const oldUrl = /"url":"(\.\/project-assets\/[^"]+)"/.exec(oldProps)[1];
  const oldBytes = Buffer.from(await (await fetch(new URL(oldUrl, `${base}/preview/${runId}/`))).arrayBuffer());
  await fixture(workDir, 15);
  await page.reload();
  await image.evaluate(img => img.decode());
  assert.notDeepEqual(await image.screenshot(), oldPixels);
  const newProps = await (await fetch(propsUrl)).text();
  assert.notEqual(newProps, oldProps);
  const newUrl = /"url":"(\.\/project-assets\/[^"]+)"/.exec(newProps)[1];
  assert.notEqual(newUrl, oldUrl);
  const response = await fetch(new URL(newUrl, `${base}/preview/${runId}/`));
  assert.equal(response.status, 200);
  assert.notDeepEqual(Buffer.from(await response.arrayBuffer()), oldBytes);
  assert.equal((await fetch(new URL(oldUrl, `${base}/preview/${runId}/`))).status, 404);
  assert.equal((await fetch(new URL(newUrl.replace('alpha', 'bravo'), `${base}/preview/${runId}/`))).status, 404);
  assert.equal((await fetch(new URL(`${newUrl}&extra=1`, `${base}/preview/${runId}/`))).status, 404);
  assert.equal(await fs.readFile(path.join(workDir, 'runs', runId, 'source.json'), 'utf8'), before);
  assert.equal((await listObjectives(workDir)).length, 0);
  const posts = [];
  page.on('request', request => { if (request.method() === 'POST') posts.push(request.url()); });
  await page.goto(base);
  const selected = page.locator('#projectChecks input[value="alpha"]');
  await selected.check();
  const refreshed = page.waitForResponse(response => response.url().endsWith('/api/project-catalog'));
  await page.getByRole('button', { name: 'REFRESH IMAGE CATALOG', exact: true }).click();
  await refreshed;
  assert.equal(await selected.isChecked(), true);
  assert.equal(posts.length, 0);
  assert.equal((await listObjectives(workDir)).length, 0);
  await page.getByLabel('Project name', { exact: true }).fill('Curated portfolio');
  await page.getByLabel('Client request', { exact: true }).fill('Build a gallery of the selected project images.');
  await page.getByRole('button', { name: 'START GENERATION', exact: true }).click();
  await page.getByText(/This generation runs once/).waitFor();
  const queued = await listObjectives(workDir);
  assert.equal(queued.length, 1);
  assert.deepEqual(queued[0].clientProjectIds, ['alpha']);
});

test('client browser uses two asset inputs and rejects hardcoded image URLs and external requests', { timeout: 90000 }, async t => {
  const workDir = await workspace(t);
  await fixture(workDir);
  for (const seed of [1, 2]) {
    const result = await evaluateProjectCandidate({ workDir, task, taskId: 'dynamic', seed, files });
    assert.equal(result.passed, true, result.errors.join('\n'));
    assert.equal(result.retainLesson, false);
  }
  const catalog = await loadProjectCatalog(workDir, ['alpha']);
  const hardcoded = { ...files, 'App.jsx': files['App.jsx'].replace('src={i.url}', `src="${catalog.projects[0].images[0].url}"`) };
  const stale = await evaluateProjectCandidate({ workDir, task, taskId: 'hardcoded', seed: 2, files: hardcoded });
  assert.equal(stale.passed, false);
  const external = { ...files, 'App.jsx': files['App.jsx'].replace('<main>', '<main><img src="https://example.org/private.png" alt="denied"/>') };
  const denied = await evaluateProjectCandidate({ workDir, task, taskId: 'external', files: external });
  assert.equal(denied.passed, false);
  assert.ok(denied.checks.some(check => check.name === 'asset-isolation' && !check.passed));
  await assert.rejects(evaluateProjectCandidate({ workDir, task: { ...task, objectiveMode: 'qualify' }, files }), /non-qualifying/);
});

test('static client export rechecks source and current assets and copies the preview bytes', { timeout: 90000 }, async t => {
  const workDir = await workspace(t);
  await fixture(workDir);
  await receipt(workDir);
  const output = path.join(workDir, 'export');
  const result = await exportProjectSite(workDir, runId, output);
  assert.deepEqual(result.checkedSeeds, [1, 2]);
  const catalog = await loadProjectCatalog(workDir, ['alpha']);
  const image = catalog.projects[0].images[0];
  assert.deepEqual(await fs.readFile(path.join(output, image.url.slice(2).split('?')[0])), [...catalog.assets.values()][0].bytes);
  assert.match(await fs.readFile(path.join(output, 'props.js'), 'utf8'), new RegExp(image.sha256));
  await writeJson(path.join(workDir, 'runs', runId, 'source.json'), { ...files, 'styles.css': 'body{display:none}' });
  await assert.rejects(exportProjectSite(workDir, runId, path.join(workDir, 'bad-export')), /changed since verification/);
  assert.equal((await listObjectives(workDir)).length, 0);
});
