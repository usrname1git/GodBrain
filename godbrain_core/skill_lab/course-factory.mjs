import path from 'node:path';
import { COMPETENCIES, CAPSTONE_CONTEXTS, CAPSTONE_DIRECTIONS } from './competencies.mjs';
import { documentationUrl } from './docs.mjs';
import { readJson, writeJson } from './gym-core.mjs';
import { validateVerifierSpec } from './verifier-dsl.mjs';

const VERSION = 1;
const MAX_COURSES = 120;
export const COURSE_DEFINITION_VERSION = 9;

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
    capstoneSequence: 0,
    archivedCapstones: 0,
    courses: [],
  });
  value.archivedCapstones ??= 0;
  if (value.version !== VERSION || !Array.isArray(value.courses) ||
      !Number.isSafeInteger(value.capstoneSequence) || value.capstoneSequence < 0 ||
      !Number.isSafeInteger(value.archivedCapstones) || value.archivedCapstones < 0) {
    throw new Error('Frontend university state is damaged.');
  }
  return value;
}

export async function listUniversityTasks(workDir, trustedTasks) {
  const university = await readUniversity(workDir);
  return university.courses.map(course => asTask(course, trustedTasks));
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
  if (!university.courses.some(course => course.status === 'active')) {
    const next = COMPETENCIES.find(blueprint =>
      !university.courses.some(course => course.competencyId === blueprint.id) &&
      prerequisitesMet(blueprint, university.courses));
    if (next) {
      university.courses.push(makeCourse(next, trustedTasks));
      changed = true;
    } else if (COMPETENCIES.every(blueprint =>
      university.courses.some(course => course.competencyId === blueprint.id && course.status === 'mastered'))) {
      if (university.courses.length >= MAX_COURSES) {
        const archived = university.courses.findIndex(course =>
          course.competencyId === 'product-site-capstone' &&
          course.iteration > 1 &&
          course.status === 'mastered');
        if (archived < 0) throw new Error(`Frontend university course capacity (${MAX_COURSES}) reached.`);
        university.courses.splice(archived, 1);
        university.archivedCapstones++;
      }
      university.capstoneSequence++;
      const iteration = university.capstoneSequence + 1;
      const context = CAPSTONE_CONTEXTS[(iteration - 2) % CAPSTONE_CONTEXTS.length];
      const direction = CAPSTONE_DIRECTIONS[(iteration - 2) % CAPSTONE_DIRECTIONS.length];
      const blueprint = COMPETENCIES.find(item => item.id === 'product-site-capstone');
      university.courses.push(makeCourse(blueprint, trustedTasks, iteration,
        `For this studio, design ${context} using ${direction}. Do not reuse a prior composition.`));
      changed = true;
    }
  }
  if (changed) await writeJson(path.join(workDir, 'university.json'), university);
  return university;
}

export function universitySummary(university, masteryRows = []) {
  const masteryById = new Map(masteryRows.map(row => [row.id, row]));
  const courses = university.courses.map(course => ({
    id: course.id,
    title: course.title,
    discipline: course.discipline,
    level: course.level,
    iteration: course.iteration,
    status: course.status,
    mastery: masteryById.get(course.id)?.mastery ?? 'queued',
    recentAttempts: masteryById.get(course.id)?.recentAttempts ?? 0,
    recentPassed: masteryById.get(course.id)?.recentPassed ?? 0,
    recentFailed: masteryById.get(course.id)?.recentFailed ?? 0,
    recentPassRate: masteryById.get(course.id)?.recentPassRate ?? 0,
  }));
  return {
    blueprintCount: COMPETENCIES.length,
    generatedCount: courses.length + university.archivedCapstones,
    archivedCapstones: university.archivedCapstones,
    masteredCount: courses.filter(course => course.status === 'mastered').length,
    active: courses.find(course => course.status === 'active') ?? null,
    courses: courses.slice().reverse().slice(0, 12),
  };
}
