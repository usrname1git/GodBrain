import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { promises as fs } from 'node:fs';
import { existsSync } from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { chromium } from '../skill_lab/node_modules/playwright/index.mjs';
import { readProjectCatalogDirectory } from '../skill_lab/project-assets.mjs';

const directory = path.dirname(fileURLToPath(import.meta.url));
const batch = process.env.GODBRAIN_SHOWCASE_BATCH;
const checkout = process.env.GODBRAIN_PORTFOLIO_CHECKOUT;
const browserPath = process.env.GODBRAIN_BROWSER ?? [
  'C:\\Program Files\\BraveSoftware\\Brave-Browser\\Application\\brave.exe',
  path.join(process.env['ProgramFiles(x86)'] ?? 'C:\\Program Files (x86)', 'Microsoft', 'Edge', 'Application', 'msedge.exe'),
  path.join(process.env.ProgramFiles ?? 'C:\\Program Files', 'Google', 'Chrome', 'Application', 'chrome.exe'),
].find(candidate => existsSync(candidate));

test('actual static batch loads all bound images, filters, zooms and preserves both portfolio themes on desktop/mobile', { timeout: 60000 }, async t => {
  assert.ok(batch && checkout, 'Set GODBRAIN_SHOWCASE_BATCH and GODBRAIN_PORTFOLIO_CHECKOUT to the reviewed local batch and dedicated checkout.');
  const site = path.join(batch, 'site');
  const catalog = await readProjectCatalogDirectory(site);
  const summary = projects => `${projects.length} project${projects.length === 1 ? '' : 's'} / ${projects.reduce((sum, project) => sum + project.images.length, 0)} images`;
  const searchable = project => `${project.title} ${project.description} ${project.images.map(image => image.description).join(' ')}`.toLowerCase();
  const reclaimed = catalog.projects.filter(project => searchable(project).includes('reclaim11'));
  assert.ok(reclaimed.length, 'Reviewed batch must include Reclaim11');
  const imageDescription = catalog.projects.flatMap(project => project.images).map(image => image.description)
    .find(description => !catalog.projects.some(project => `${project.title} ${project.description}`.toLowerCase().includes(description.toLowerCase())));
  assert.ok(imageDescription, 'Reviewed batch needs an image-only description to exercise screenshot search');
  const detailed = catalog.projects.filter(project => searchable(project).includes(imageDescription.toLowerCase()));
  const server = http.createServer(async (request, response) => {
    try {
      const url = new URL(request.url, 'http://127.0.0.1');
      let file;
      if (url.pathname === '/assets/js/theme.js') file = path.join(checkout, 'assets', 'js', 'theme.js');
      else if (url.pathname.startsWith('/projects/')) {
        const relative = url.pathname.slice('/projects/'.length) || 'index.html';
        assert.ok(!relative.includes('..') && !relative.includes('\\'));
        file = path.join(site, ...relative.split('/'));
      } else throw new Error('Unapproved static route');
      const type = { '.js': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.webp': 'image/webp', '.png': 'image/png', '.html': 'text/html' }[path.extname(file)];
      assert.ok(type);
      response.writeHead(200, { 'Content-Type': type, 'Cache-Control': 'no-store' });
      response.end(await fs.readFile(file));
    } catch { response.writeHead(404); response.end(); }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => { server.closeAllConnections(); server.close(resolve); }));
  const origin = `http://127.0.0.1:${server.address().port}`;
  const browser = await chromium.launch({
    executablePath: browserPath,
    headless: true, chromiumSandbox: true, args: ['--disable-gpu', '--disable-extensions'],
  });
  t.after(() => browser.close());
  const page = await browser.newPage();
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  for (const width of [1280, 390]) {
    await page.setViewportSize({ width, height: 900 });
    await page.goto(`${origin}/projects/`);
    await page.getByText(summary(catalog.projects), { exact: true }).waitFor();
    assert.equal(await page.locator('#projects article').count(), catalog.projects.length);
    for (const image of await page.locator('figure img').all()) {
      await image.scrollIntoViewIfNeeded();
      await image.evaluate(img => img.decode());
      const src = await image.getAttribute('src');
      const actual = Buffer.from(await (await fetch(new URL(src, `${origin}/projects/`))).arrayBuffer());
      assert.equal(createHash('sha256').update(actual).digest('hex'), new URL(src, origin).searchParams.get('v'));
    }
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), true);
    const clipshare = catalog.projects.find(project => project.id === 'clipshare');
    if (clipshare) {
      await page.getByLabel('Find a project').fill('ClipShare');
      await page.getByText(summary([clipshare]), { exact: true }).waitFor();
      const article = page.locator('#projects article');
      assert.equal(await article.count(), 1);
      assert.equal(await article.getByRole('link', { name: 'Project', exact: true }).getAttribute('href'), clipshare.url);
      await article.locator('figure button').first().click();
      await page.locator('#caption').getByText('source-workflow-illustration', { exact: false }).waitFor();
      await page.keyboard.press('Escape');
    }
    await page.getByLabel('Find a project').fill('Reclaim11');
    await page.getByText(summary(reclaimed), { exact: true }).waitFor();
    await page.locator('figure button').first().click();
    assert.equal(await page.locator('dialog').evaluate(dialog => dialog.open), true);
    await page.keyboard.press('Escape');
    assert.equal(await page.locator('dialog').evaluate(dialog => dialog.open), false);
    await page.getByLabel('Find a project').fill(imageDescription);
    await page.getByText(summary(detailed), { exact: true }).waitFor();
    assert.equal(await page.locator('#projects article').count(), detailed.length);
    await page.getByLabel('Find a project').fill('');
    const toggle = page.locator('[data-theme-toggle]');
    await toggle.click();
    const flashbang = await page.locator('body').evaluate(body => body.classList.contains('flashbang'));
    await page.reload();
    assert.equal(await page.locator('body').evaluate(body => body.classList.contains('flashbang')), flashbang);
    await page.emulateMedia({ media: 'print' });
    assert.equal(await page.locator('body').evaluate(body => getComputedStyle(body).backgroundColor), 'rgb(255, 255, 255)');
    await page.emulateMedia({ media: 'screen' });
    if (process.env.GODBRAIN_SHOWCASE_PROOF) {
      await fs.mkdir(process.env.GODBRAIN_SHOWCASE_PROOF, { recursive: true });
      await page.screenshot({ path: path.join(process.env.GODBRAIN_SHOWCASE_PROOF, `gallery-${width}.png`), fullPage: true });
    }
  }
  assert.deepEqual(errors, []);
  assert.equal(catalog.assets.size, catalog.projects.reduce((sum, project) => sum + project.images.length, 0));
});
