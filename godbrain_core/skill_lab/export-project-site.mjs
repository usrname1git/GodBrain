import { promises as fs } from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { parseArgs } from 'node:util';
import { buildBundle, outputText } from './browser.mjs';
import { hashFiles, readJson } from './gym-core.mjs';
import { loadProjectCatalog } from './project-assets.mjs';
import { evaluateProjectCandidate } from './project-browser.mjs';

export async function exportProjectSite(workDir, runId, output) {
  if (!/^[0-9]{8}-[a-f0-9]{12}$/.test(runId)) throw new Error('Invalid client source run.');
  const receipt = await readJson(path.join(workDir, 'runs', runId, 'receipt.json'), null);
  if (receipt?.passed !== true || receipt.objectiveMode !== 'explore' ||
      receipt.clientAssetProfile !== 'client-project-assets-v1' || !receipt.clientProjectIds?.length) {
    throw new Error('Export requires a passing project-image client run, not a course lesson.');
  }
  const source = await readJson(path.join(workDir, 'runs', runId, 'source.json'), null);
  if (!source || hashFiles(source) !== receipt.sourceHash) throw new Error('Client source is missing or changed since verification.');
  const catalog = await loadProjectCatalog(workDir, receipt.clientProjectIds);
  for (const seed of [1, 2]) {
    const result = await evaluateProjectCandidate({
      workDir, files: source, taskId: receipt.taskId, seed,
      task: { title: receipt.taskId, objectiveMode: 'explore', retainLesson: false, clientProjectIds: receipt.clientProjectIds },
    });
    if (!result.passed || result.catalogHash !== catalog.catalogHash) {
      throw new Error(`Current export assets failed client rendering: ${result.errors.join('; ')}`);
    }
  }
  const bundle = await buildBundle(source);
  const props = { objectiveTitle: receipt.taskId, objectiveSeed: receipt.seeds?.[0] ?? 1, projects: catalog.projects };
  await fs.mkdir(output, { recursive: false });
  await fs.writeFile(path.join(output, 'index.html'), `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self'; connect-src 'none'; frame-src 'none'; worker-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'"><link rel="stylesheet" href="./bundle.css"></head><body><div id="root"></div><script src="./props.js"></script><script src="./bundle.js"></script></body></html>`);
  await fs.writeFile(path.join(output, 'bundle.js'), outputText(bundle, '.js'));
  await fs.writeFile(path.join(output, 'bundle.css'), outputText(bundle, '.css'));
  await fs.writeFile(path.join(output, 'props.js'), `window.__GODBRAIN_TASK_PROPS__=${JSON.stringify(props).replace(/</g, '\\u003c')};`);
  for (const [url, asset] of catalog.assets) {
    const relative = url.slice(1).split('?')[0];
    const target = path.join(output, ...relative.split('/'));
    await fs.mkdir(path.dirname(target), { recursive: true });
    await fs.writeFile(target, asset.bytes, { flag: 'wx' });
  }
  return { ok: true, runId, sourceHash: receipt.sourceHash, catalogHash: catalog.catalogHash, images: catalog.assets.size, checkedSeeds: [1, 2] };
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  const { values } = parseArgs({ options: {
    'work-dir': { type: 'string' }, 'run-id': { type: 'string' }, output: { type: 'string' },
  } });
  if (!values['work-dir'] || !values['run-id'] || !values.output) throw new Error('--work-dir, --run-id and --output are required.');
  console.log(JSON.stringify(await exportProjectSite(values['work-dir'], values['run-id'], values.output)));
}
