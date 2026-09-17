import assert from 'node:assert/strict';
import { promises as fs } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { COMPETENCIES } from './competencies.mjs';
import {
  advanceUniversity, COURSE_DEFINITION_VERSION, listUniversityTasks, readUniversity, universitySummary,
} from './course-factory.mjs';
import { writeJson } from './gym-core.mjs';
import { validateGeneratedSource, validateVerifierSpec } from './verifier-dsl.mjs';

const labRoot = path.dirname(fileURLToPath(import.meta.url));
const trustedTasks = [...new Set(COMPETENCIES.map(item => item.contractTaskId))].map(id => ({
  id, title: id, family: 'trusted', brief: `Trusted contract for ${id}.`, docs: [],
  qualityProfile: 'trusted-v1',
}));

async function workspace(t) {
  const root = path.join(labRoot, 'work', 'tests');
  await fs.mkdir(root, { recursive: true });
  const dir = await fs.mkdtemp(path.join(root, 'university-'));
  t.after(() => fs.rm(dir, { recursive: true, force: true }));
  return dir;
}

test('verifier DSL rejects unknown contracts, fields and unsafe type escapes', () => {
  const valid = {
    version: 1,
    contractTaskId: trustedTasks[0].id,
    fileMode: 'both',
    appFile: 'App.tsx',
    evaluationProfile: 'full',
    sourceRules: ['typescript-component', 'responsive-styles'],
    maxTokens: 4096,
  };
  assert.deepEqual(validateVerifierSpec(valid, trustedTasks), valid);
  assert.throws(() => validateVerifierSpec({ ...valid, execute: 'arbitrary code' }, trustedTasks),
    /Unsupported verifier/);
  assert.throws(() => validateVerifierSpec({ ...valid, contractTaskId: 'invented' }, trustedTasks),
    /unknown trusted contract/);
  const task = { verifierSpec: valid };
  assert.match(validateGeneratedSource(task, {
    'App.tsx': 'export default function App(props:any){return <main/>}',
    'styles.css': '@media(max-width:600px){}',
  }), /props interface|type/);
  assert.equal(validateGeneratedSource(task, {
    'App.tsx': 'type AppProps={name:string};export default function App({name}:AppProps){return <main>{name}</main>}',
    'styles.css': '@media(max-width:600px){main{display:block}}',
  }), null);
  const stateTask = {
    verifierSpec: { ...valid, sourceRules: ['typescript-component', 'react-state'] },
  };
  assert.equal(validateGeneratedSource(stateTask, {
    'App.tsx': 'import {useState} from "react";type AppProps={name:string};export default function App({name}:AppProps){const [value]=useState<string>(name);return <main>{value}</main>}',
    'styles.css': '',
  }), null);
  assert.match(validateGeneratedSource(stateTask, {
    'App.tsx': 'type AppProps={name:string};export default function App({name}:AppProps){return <main>{name}</main>}',
    'styles.css': '',
  }), /real React state/);
});

test('definition bump retargets the four-suite composition course', async t => {
  const workDir = await workspace(t);
  await writeJson(path.join(workDir, 'university.json'), {
    version: 1, capstoneSequence: 0, archivedCapstones: 0, courses: [{
      id: 'university-interaction-composition-v1',
      competencyId: 'interaction-composition',
      discipline: 'Application UX',
      level: 3,
      iteration: 1,
      title: 'Compose navigation, exploration and forms',
      prerequisites: ['accessible-navigation', 'derived-state', 'form-validation'],
      docs: [{ title: 'Thinking in React', url: 'https://react.dev/learn/thinking-in-react' }],
      focus: 'old four-suite exam',
      verifierSpec: {
        version: 1,
        contractTaskId: 'event-platform-showcase-v1',
        fileMode: 'app',
        appFile: 'App.tsx',
        evaluationProfile: 'full',
        sourceRules: ['typescript-component', 'react-state', 'semantic-layout', 'form-validation'],
        maxTokens: 4096,
      },
      status: 'active',
      createdAt: '2026-09-16T00:00:00.000Z',
      validatedAt: '2026-09-16T00:00:00.000Z',
      masteredAt: null,
      validationProfile: 'trusted-contract-extension-v1',
      definitionVersion: 7,
    }],
  });
  const university = await advanceUniversity(workDir, [], trustedTasks);
  const course = university.courses.find(item => item.id === 'university-interaction-composition-v1');
  assert.equal(course.verifierSpec.contractTaskId, 'responsive-site-navigation-v1');
  assert.equal(course.definitionVersion, COURSE_DEFINITION_VERSION);
  assert.ok(course.retargetedAt);
});

test('definition bump retargets capstone studios without crowning old mastery', async t => {
  const workDir = await workspace(t);
  await writeJson(path.join(workDir, 'university.json'), {
    version: 1, capstoneSequence: 1, archivedCapstones: 0, courses: [{
      id: 'university-product-site-capstone-v2',
      competencyId: 'product-site-capstone',
      discipline: 'Capstone',
      level: 4,
      iteration: 2,
      title: 'Deliver an integrated typed product-site capstone · studio 2',
      prerequisites: ['interaction-composition', 'lifecycle-form-composition', 'responsive-product-system'],
      docs: [{ title: 'Thinking in React', url: 'https://react.dev/learn/thinking-in-react' }],
      focus: 'For this studio, design a privacy-first analytics platform using editorial minimalism.',
      verifierSpec: {
        version: 1,
        contractTaskId: 'event-platform-showcase-v1',
        fileMode: 'app',
        appFile: 'App.tsx',
        evaluationProfile: 'full',
        sourceRules: ['typescript-component', 'react-state', 'semantic-layout', 'form-validation'],
        maxTokens: 4096,
      },
      status: 'active',
      createdAt: '2026-09-16T00:00:00.000Z',
      validatedAt: '2026-09-16T00:00:00.000Z',
      masteredAt: null,
      validationProfile: 'trusted-contract-extension-v1',
      definitionVersion: 8,
    }],
  });
  const university = await advanceUniversity(workDir, [{
    id: 'university-product-site-capstone-v2',
    mastery: 'mastered',
    recentAttempts: 20,
    recentPassRate: 1,
  }], trustedTasks);
  const studio = university.courses.find(item => item.id === 'university-product-site-capstone-v2');
  assert.equal(studio.definitionVersion, COURSE_DEFINITION_VERSION);
  assert.ok(studio.retargetedAt);
  assert.equal(studio.status, 'active');
  assert.match(studio.title, /studio 2/);
  assert.match(studio.focus, /privacy-first/);
});

test('L3 composition is nav+form and explorer+form, not the four-suite showcase', () => {
  const composition = COMPETENCIES.find(item => item.id === 'interaction-composition');
  assert.equal(composition.contractTaskId, 'responsive-site-navigation-v1');
  assert.ok(composition.sourceRules.includes('form-validation'));
  const explorer = COMPETENCIES.find(item => item.id === 'lifecycle-form-composition');
  assert.equal(explorer.contractTaskId, 'feature-lifecycle-explorer-v1');
  assert.ok(explorer.sourceRules.includes('form-validation'));
  const capstone = COMPETENCIES.find(item => item.id === 'product-site-capstone');
  assert.equal(capstone.contractTaskId, 'event-platform-showcase-v1');
  assert.deepEqual(capstone.prerequisites, [
    'interaction-composition', 'lifecycle-form-composition', 'responsive-product-system',
  ]);
});

test('university opens prerequisites one course at a time and then creates new capstones', async t => {
  const workDir = await workspace(t);
  let university = await advanceUniversity(workDir, [], trustedTasks);
  assert.equal(university.courses.length, 1);
  assert.equal(university.courses[0].competencyId, 'component-composition');
  let tasks = await listUniversityTasks(workDir, trustedTasks);
  assert.equal(tasks[0].appFile, 'App.tsx');
  assert.equal(tasks[0].fileMode, 'app');
  assert.equal(tasks[0].baseTaskId, 'marketing-site-architecture-v1');

  for (let index = 0; index < COMPETENCIES.length; index++) {
    university = await readUniversity(workDir);
    const active = university.courses.find(course => course.status === 'active');
    assert.ok(active, `expected active course at step ${index}`);
    university = await advanceUniversity(workDir, [{
      id: active.id, mastery: 'mastered', recentAttempts: 20, recentPassRate: 1,
    }], trustedTasks);
  }

  const fixed = university.courses.filter(course => course.iteration === 1);
  assert.equal(fixed.length, COMPETENCIES.length);
  assert.equal(fixed.every(course => course.status === 'mastered'), true);
  const studio = university.courses.find(course => course.iteration === 2);
  assert.ok(studio);
  assert.equal(studio.competencyId, 'product-site-capstone');
  assert.equal(studio.status, 'active');
  const summary = universitySummary(university, []);
  assert.equal(summary.blueprintCount, COMPETENCIES.length);
  assert.equal(summary.active.id, studio.id);

  tasks = await listUniversityTasks(workDir, trustedTasks);
  assert.equal(tasks.some(task => task.id === studio.id), true);
});
