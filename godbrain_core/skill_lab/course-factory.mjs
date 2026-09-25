import path from 'node:path';
import { COMPETENCIES, PROGRAM } from './competencies.mjs';
import { documentationUrl } from './docs.mjs';
import { readJson, writeJson } from './gym-core.mjs';
import { validateVerifierSpec } from './verifier-dsl.mjs';

const VERSION = 1;
export const COURSE_DEFINITION_VERSION = 13;

function courseId(competencyId, iteration = 1) {
  return `university-${competencyId}-v${iteration}`;
}

function verifierFor(blueprint) {
  return {
    version: 1,
    contractTaskId: blueprint.contractTaskId,
    fileMode: blueprint.fileMode,
    appFile: blueprint.appFile,
    evaluationProfile: 'full',
    sourceRules: blueprint.sourceRules,
    maxTokens: blueprint.fileMode === 'styles' ? 4096 : 4096,
  };
}

function validateBlueprint(blueprint, trustedTasks) {
  if (!/^[a-z0-9-]{3,80}$/.test(blueprint.id) ||
      !Number.isSafeInteger(blueprint.level) || blueprint.level < 1 || blueprint.level > 9 ||
      !Number.isSafeInteger(blueprint.cycle) || blueprint.cycle < 1 ||
      !Number.isSafeInteger(blueprint.stage) || blueprint.stage < 1 ||
      !Array.isArray(blueprint.prerequisites) || !Array.isArray(blueprint.docs) ||
      blueprint.docs.length < 1 || blueprint.docs.length > 2) {
    throw new Error(`Invalid university competency ${blueprint.id}.`);
  }
  for (const reference of blueprint.docs) documentationUrl(reference.url);
  return validateVerifierSpec(verifierFor(blueprint), trustedTasks);
}

function makeCourse(blueprint, trustedTasks, iteration = 1, extraFocus = '') {
  const verifierSpec = validateBlueprint(blueprint, trustedTasks);
  const now = new Date().toISOString();
  return {
    id: courseId(blueprint.id, iteration),
    competencyId: blueprint.id,
    discipline: blueprint.discipline,
    level: blueprint.level,
    cycle: blueprint.cycle,
    stage: blueprint.stage,
    iteration,
    title: iteration === 1 ? blueprint.title : `${blueprint.title} · studio ${iteration}`,
    prerequisites: [...blueprint.prerequisites],
    docs: blueprint.docs,
    focus: [blueprint.focus, extraFocus].filter(Boolean).join(' '),
    verifierSpec,
    status: 'active',
    createdAt: now,
    validatedAt: now,
    masteredAt: null,
    validationProfile: 'trusted-contract-extension-v1',
    definitionVersion: COURSE_DEFINITION_VERSION,
  };
}

function asTask(course, trustedTasks) {
  const base = trustedTasks.find(task => task.id === course.verifierSpec.contractTaskId);
  if (!base) throw new Error(`University course ${course.id} lost trusted contract ${course.verifierSpec.contractTaskId}.`);
  const verifierSpec = validateVerifierSpec(course.verifierSpec, trustedTasks);
  return {
    id: course.id,
    title: course.title,
    family: `university-${course.discipline.toLowerCase().replace(/[^a-z0-9]+/g, '-')}`,
    qualityProfile: 'frontend-university-v1',
    docs: course.docs,
    baseTaskId: verifierSpec.contractTaskId,
    brief: [
      `UNIVERSITY COURSE · Level ${course.level} · ${course.discipline}`,
      course.focus,
      `Trusted browser contract that must still pass:\n${base.brief}`,
    ].join('\n\n'),
    fileMode: verifierSpec.fileMode,
    appFile: verifierSpec.appFile,
    evaluationProfile: verifierSpec.evaluationProfile,
    maxTokens: verifierSpec.maxTokens,
    verifierSpec,
    university: {
      competencyId: course.competencyId,
      level: course.level,
      cycle: course.cycle ?? null,
      stage: course.stage ?? null,
      iteration: course.iteration,
      definitionVersion: course.definitionVersion,
      status: course.status,
      retargetedAt: course.retargetedAt ?? null,
    },
  };
}

export async function readUniversity(workDir) {
  const value = await readJson(path.join(workDir, 'university.json'), {
    version: VERSION,
    programId: PROGRAM.id,
    programStatus: 'enrolled',
    capstoneSequence: 0,
    archivedCapstones: 0,
    courses: [],
  });
  value.archivedCapstones ??= 0;
  value.programId ??= PROGRAM.id;
  value.programStatus ??= 'enrolled';
  if (value.version !== VERSION || !Array.isArray(value.courses) ||
      !Number.isSafeInteger(value.capstoneSequence) || value.capstoneSequence < 0 ||
      !Number.isSafeInteger(value.archivedCapstones) || value.archivedCapstones < 0 ||
      !['enrolled', 'graduated'].includes(value.programStatus)) {
    throw new Error('Frontend university state is damaged.');
  }
  return value;
}

export async function listUniversityTasks(workDir, trustedTasks) {
  const university = await readUniversity(workDir);
  const tasks = [];
  for (const course of university.courses) {
    if (course.status === 'retired' || course.iteration !== 1) continue;
    const contractId = course.verifierSpec?.contractTaskId;
    if (!trustedTasks.some(task => task.id === contractId)) continue;
    tasks.push(asTask(course, trustedTasks));
  }
  return tasks;
}

function competencyMastered(courses, competencyId) {
  return courses.some(course =>
    course.competencyId === competencyId &&
    course.iteration === 1 &&
    course.status === 'mastered');
}

function ladderMastered(courses) {
  return COMPETENCIES.every(blueprint => competencyMastered(courses, blueprint.id));
}

function prerequisitesMet(blueprint, courses) {
  return blueprint.prerequisites.every(id =>
    courses.some(course => course.competencyId === id && course.status === 'mastered'));
}

export async function advanceUniversity(workDir, masteryRows, trustedTasks) {
  const university = await readUniversity(workDir);
  let changed = false;
  const masteryById = new Map(masteryRows.map(row => [row.id, row]));
  for (const course of university.courses) {
    const blueprint = COMPETENCIES.find(item => item.id === course.competencyId) ?? null;
    const retargeting = Boolean(blueprint) && course.definitionVersion !== COURSE_DEFINITION_VERSION;
    if (retargeting) {
      course.discipline = blueprint.discipline;
      course.level = blueprint.level;
      course.cycle = blueprint.cycle;
      course.stage = blueprint.stage;
      course.prerequisites = [...blueprint.prerequisites];
      course.docs = blueprint.docs;
      course.verifierSpec = validateBlueprint(blueprint, trustedTasks);
      if (course.iteration === 1) {
        course.title = blueprint.title;
        course.focus = blueprint.focus;
      }
      course.definitionVersion = COURSE_DEFINITION_VERSION;
      course.retargetedAt = new Date().toISOString();
      changed = true;
    }
    if (!retargeting && course.status === 'active' && masteryById.get(course.id)?.mastery === 'mastered') {
      course.status = 'mastered';
      course.masteredAt = new Date().toISOString();
      changed = true;
    }
  }
  if (competencyMastered(university.courses, 'product-site-capstone')) {
    for (const course of university.courses) {
      if (course.competencyId === 'product-site-capstone' && course.iteration > 1 && course.status === 'active') {
        course.status = 'retired';
        changed = true;
      }
    }
  }
  if (!university.courses.some(course => course.status === 'active')) {
    const next = COMPETENCIES.find(blueprint =>
      !university.courses.some(course => course.competencyId === blueprint.id && course.iteration === 1) &&
      prerequisitesMet(blueprint, university.courses));
    if (next) {
      university.courses.push(makeCourse(next, trustedTasks));
      university.programStatus = 'enrolled';
      changed = true;
    }
  }
  if (ladderMastered(university.courses) &&
      !university.courses.some(course => course.status === 'active') &&
      university.programStatus !== 'graduated') {
    university.programStatus = 'graduated';
    university.graduatedAt = new Date().toISOString();
    changed = true;
  }
  if (changed) await writeJson(path.join(workDir, 'university.json'), university);
  return university;
}

export function universitySummary(university, masteryRows = []) {
  const masteryById = new Map(masteryRows.map(row => [row.id, row]));
  const degree = university.courses
    .filter(course => course.iteration === 1)
    .map(course => ({
      id: course.id,
      title: course.title,
      discipline: course.discipline,
      level: course.level,
      cycle: course.cycle ?? null,
      stage: course.stage ?? null,
      iteration: course.iteration,
      status: course.status,
      mastery: masteryById.get(course.id)?.mastery ?? 'queued',
      recentAttempts: masteryById.get(course.id)?.recentAttempts ?? 0,
      recentPassed: masteryById.get(course.id)?.recentPassed ?? 0,
      recentFailed: masteryById.get(course.id)?.recentFailed ?? 0,
      recentPassRate: masteryById.get(course.id)?.recentPassRate ?? 0,
    }))
    .sort((a, b) => (a.cycle ?? 99) - (b.cycle ?? 99) || (a.stage ?? 99) - (b.stage ?? 99) || a.title.localeCompare(b.title));
  const active = university.courses.find(course => course.status === 'active') ?? null;
  const studying = active && active.iteration === 1 ? degree.find(course => course.id === active.id) : null;
  return {
    programId: PROGRAM.id,
    programTitle: PROGRAM.title,
    programStatus: university.programStatus ?? 'enrolled',
    blueprintCount: COMPETENCIES.length,
    generatedCount: degree.length,
    archivedCapstones: university.archivedCapstones,
    masteredCount: degree.filter(course => course.status === 'mastered').length,
    currentCycle: studying?.cycle ?? null,
    currentStage: studying?.stage ?? null,
    graduatedAt: university.graduatedAt ?? null,
    active: studying ?? null,
    courses: degree,
  };
}
