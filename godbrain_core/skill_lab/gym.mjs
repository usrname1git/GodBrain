import { execFile } from 'node:child_process';
import { createHash } from 'node:crypto';
import { promises as fs } from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { parseArgs, promisify } from 'node:util';
import { hashFiles, localEndpoint, loadState, readJson, requestStop, runPractice, StopRequested, universityAppScaffold } from './gym-core.mjs';
import { createDocumentationReader } from './docs.mjs';
import { startDashboard } from './dashboard.mjs';
import {
  claimObjective, completeObjective, listObjectives, objectiveIsTerminal,
} from './objectives.mjs';
import { advanceCampaigns } from './coach.mjs';
import {
  advanceUniversity, COURSE_DEFINITION_VERSION, listUniversityTasks, readUniversity, universitySummary,
} from './course-factory.mjs';
import { masterySnapshot, selectCurriculumTask } from './scheduler.mjs';
import { getReference } from './references.mjs';

const execute = promisify(execFile);
const labRoot = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(labRoot, '..', '..');

export function parseOptions(args) {
  const { values, positionals } = parseArgs({
    args, allowPositionals: true,
    options: {
      continuous: { type: 'boolean', default: false },
      endpoint: { type: 'string' }, model: { type: 'string' },
      'teacher-endpoint': { type: 'string' }, 'teacher-model': { type: 'string' },
      'work-dir': { type: 'string', default: path.join(labRoot, 'work', 'gym') },
      rounds: { type: 'string', default: '1' },
      'max-attempts': { type: 'string', default: '4' },
      'keep-runs': { type: 'string', default: '24' },
      'max-tokens': { type: 'string', default: '2400' },
      'timeout-seconds': { type: 'string', default: '180' },
      'interval-seconds': { type: 'string', default: '8' },
      'retry-seconds': { type: 'string', default: '30' },
      'tutor-every': { type: 'string', default: '2' },
      'dashboard-port': { type: 'string', default: '4177' },
      'no-dashboard': { type: 'boolean', default: false },
      'offline-docs': { type: 'boolean', default: false },
      browser: { type: 'string' }, task: { type: 'string' },
      json: { type: 'boolean', default: false },
      help: { type: 'boolean', default: false },
    },
  });
  if (positionals.length > 1) throw new Error('Specify only one command: run, status, stop, tasks, lessons, objectives, or university.');
  for (const name of ['rounds', 'max-attempts', 'keep-runs', 'max-tokens', 'timeout-seconds',
    'interval-seconds', 'retry-seconds', 'tutor-every', 'dashboard-port']) {
    if (!/^\d+$/.test(values[name]) || !Number.isSafeInteger(Number(values[name]))) {
      throw new Error(`--${name} must be a non-negative integer.`);
    }
  }
  return { command: values.help ? 'help' : positionals[0] ?? 'help', values };
}

export function selectRetainedLesson(lessons, taskId, evaluatorVersion, selectionCount, allowPrevious = false) {
  const taskLessons = lessons.filter(item =>
    !item.stale &&
    item.taskId === taskId);
  const current = taskLessons.filter(item => item.evaluatorVersion === evaluatorVersion);
  const eligible = current.length || !allowPrevious ? current : taskLessons;
  return eligible.length ? eligible[selectionCount % eligible.length] : null;
}

async function selectEndpoint(explicit) {
  if (explicit) return localEndpoint(explicit);
  for (const port of [8888, 8000]) {
    const base = `http://127.0.0.1:${port}/v1`;
    try {
      const response = await fetch(`${base}/models`, { signal: AbortSignal.timeout(2000), redirect: 'error' });
      const models = await response.json();
      if (response.ok && Array.isArray(models.data) && models.data.some(model => typeof model.id === 'string')) return base;
    } catch (error) {
      if (!(error instanceof TypeError || error instanceof SyntaxError) && error.name !== 'TimeoutError') throw error;
    }
  }
  // The continuous loop records the unavailable endpoint and retries; it never cold-starts a model.
  return 'http://127.0.0.1:8888/v1';
}

async function hostPauseReason(endpoint, workDir) {
  const trainingControl = await readJson(path.join(workDir, 'training-pause.json'), { paused: false });
  if (trainingControl.paused === true) return 'Frontend training is explicitly paused and saved.';
  if (process.platform !== 'win32') return null;
  const executable = path.join(process.env.SystemRoot ?? 'C:\\Windows',
    'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
  const { stdout } = await execute(executable, [
    '-NoLogo', '-NoProfile', '-NonInteractive', '-File',
    path.join(repoRoot, 'scripts', 'Get-FrontendGymPause.ps1'),
  ], { timeout: 10_000, windowsHide: true, maxBuffer: 16_000 });
  const result = JSON.parse(stdout.trim());
  if (typeof result.cs2_sleep !== 'boolean') throw new Error('Host pause probe returned an invalid response.');
  if (result.cs2_sleep) return 'CS2 is active or inside its configured resume delay.';
  if (new URL(endpoint).port === '8000') {
    const file = path.join(repoRoot, 'logs', 'mouth-pause.txt');
    let paused;
    try {
      paused = (await fs.readFile(file, 'utf8')).trim().toLowerCase();
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
    }
    if (['on', 'pause', 'paused', '1', 'true'].includes(paused)) return 'The desk mouth is explicitly paused.';
  }
  return null;
}

export async function main(args = process.argv.slice(2)) {
  const { command, values } = parseOptions(args);
  const workDir = path.resolve(values['work-dir']);
  if (command === 'help') {
    console.log(`GodBrain frontend gym
  node gym.mjs run --continuous             Practice, repair, rotate exercises; resume durable state
  node gym.mjs run --rounds 2               Complete two exercise rounds, then stop
  node gym.mjs run --task ID                Practice one named exercise
  node gym.mjs status [--json]              Read progress without using the model
  node gym.mjs stop                         Request a cooperative stop
  node gym.mjs tasks                        List the curriculum
  node gym.mjs lessons                      List hash-bound, machine-tested examples
  node gym.mjs objectives                   List custom Explore and Qualify requests
  node gym.mjs university                   Show the generated degree path and current frontier

Options: --endpoint http://127.0.0.1:8888/v1 --model ID
  --teacher-endpoint URL --teacher-model ID --tutor-every 2 (0 disables tutor)
  --max-attempts 4 --max-tokens 2400 --timeout-seconds 180
  --keep-runs 24 --work-dir PATH --browser PATH --offline-docs
  --dashboard-port 4177 --no-dashboard

One local model request at a time. No host mutations or automatic model starts.
Passing exercises become local gym lessons without /verify; they grant no host authority.`);
    return;
  }
  if (command === 'stop') {
    await requestStop(workDir);
    console.log('Stop requested. The active model request is cancelled; browser evaluation finishes within its bounded timeout.');
    return;
  }
  if (command === 'status') {
    const state = await readJson(path.join(workDir, 'state.json'), null);
    if (!state) {
      console.log(values.json ? JSON.stringify({ status: 'not_started', workDir }) : `Gym has not started: ${workDir}`);
      return;
    }
    let processAlive = false;
    if (Number.isSafeInteger(state.pid)) {
      try {
        process.kill(state.pid, 0);
        processAlive = true;
      } catch (error) {
        if (error.code !== 'ESRCH' && error.code !== 'EPERM') throw error;
        processAlive = error.code === 'EPERM';
      }
    }
    const status = {
      status: state.status, processAlive, pid: state.pid, updatedAt: state.updatedAt,
      task: state.active?.taskId ?? null, attempt: state.active?.attempt ?? 0,
      stats: state.stats, usableLessons: state.lessons.filter(item => !item.stale).length,
      lastRun: state.lastRun, lastError: state.lastError, workDir,
    };
    if (values.json) console.log(JSON.stringify(status, null, 2));
    else {
      console.log(`${status.status} | process=${processAlive ? 'alive' : 'not running'} | task=${status.task ?? '-'} | attempt=${status.attempt}`);
      console.log(`Attempts ${state.stats.attempts}; passed ${state.stats.passed}; failed ${state.stats.failed}; reusable examples ${status.usableLessons}`);
      if (state.lastError) console.log(`Last issue: ${state.lastError}`);
      console.log(`Evidence: ${workDir}`);
    }
    return;
  }
  if (command === 'lessons') {
    const state = await loadState(workDir);
    const lessons = state.lessons.map(item => ({
      ...item, evidence: path.join(workDir, 'runs', item.runId, 'receipt.json'),
    }));
    console.log(JSON.stringify(lessons, null, 2));
    return;
  }
  const { TASKS } = await import('./curriculum.mjs');
  if (command === 'university') {
    const state = await loadState(workDir);
    const generated = await listUniversityTasks(workDir, TASKS);
    const rows = await masterySnapshot(workDir, state, [...TASKS, ...generated]);
    console.log(JSON.stringify(universitySummary(await readUniversity(workDir), rows), null, 2));
    return;
  }
  if (command === 'objectives') {
    console.log(JSON.stringify(await listObjectives(workDir), null, 2));
    return;
  }
  if (!['run', 'tasks'].includes(command)) throw new Error(`Unknown command: ${command}`);
  if (command === 'tasks') {
    console.log(JSON.stringify(TASKS.map(task => ({ id: task.id, title: task.title, brief: task.brief })), null, 2));
    return;
  }
  const tasks = values.task ? TASKS.filter(task => task.id === values.task) : TASKS;
  if (!tasks.length) throw new Error(`Unknown exercise: ${values.task}`);
  const { evaluateCandidate, EVALUATOR_VERSION } = await import('./browser.mjs');
  const evaluatorHash = createHash('sha256');
  for (const file of [
    'browser.mjs', 'curriculum.mjs', 'competencies.mjs', 'course-factory.mjs',
    'verifier-dsl.mjs', 'package-lock.json',
  ]) {
    evaluatorHash.update(file).update(await fs.readFile(path.join(labRoot, file)));
  }
  const evidenceVersion = `${EVALUATOR_VERSION}:${evaluatorHash.digest('hex')}`;
  const endpoint = await selectEndpoint(values.endpoint ?? process.env.GODBRAIN_GYM_ENDPOINT);
  const controller = new AbortController();
  const stop = () => controller.abort(new StopRequested('Worker interrupted.'));
  process.once('SIGINT', stop);
  process.once('SIGTERM', stop);
  let dashboard;
  try {
    if (!values['no-dashboard']) {
      dashboard = await startDashboard({
        workDir, trustedTasks: TASKS, port: Number(values['dashboard-port']),
      });
      console.log(`Dashboard: ${dashboard.origin}`);
    }
    console.log(`Gym: ${tasks.length} exercises | learner=${endpoint} | automatic browser evidence | ${workDir}`);
    await runPractice({
      workDir, lockDir: path.join(labRoot, 'work'),
      endpoint, model: values.model, teacherEndpoint: values['teacher-endpoint'] ?? endpoint,
      teacherModel: values['teacher-model'] ?? values.model,
      token: process.env.GODBRAIN_GYM_TOKEN,
      teacherToken: process.env.GODBRAIN_GYM_TEACHER_TOKEN ?? process.env.GODBRAIN_GYM_TOKEN,
      maxAttempts: Number(values['max-attempts']), rounds: Number(values.rounds),
      continuous: values.continuous, keepRuns: Number(values['keep-runs']),
      maxTokens: Number(values['max-tokens']), timeoutMs: Number(values['timeout-seconds']) * 1000,
      intervalMs: Number(values['interval-seconds']) * 1000, retryMs: Number(values['retry-seconds']) * 1000,
      tutorEvery: Number(values['tutor-every']), browserPath: values.browser,
      externalSignal: controller.signal, pauseReason: () => hostPauseReason(endpoint, workDir),
      autoplayEnabled: async () => {
        const control = await readJson(path.join(workDir, 'training-pause.json'), { autoplay: true });
        return control.autoplay !== false;
      },
      nextTask: async () => {
        await advanceCampaigns(workDir, TASKS);
        return claimObjective(workDir, TASKS);
      },
      onObjectiveResult: (task, run, outcome) =>
        completeObjective(workDir, task.objectiveId, run, outcome),
      taskAlreadyComplete: task => objectiveIsTerminal(workDir, task.objectiveId),
      taskIsCurrent: async task =>
        !task.university || task.university.definitionVersion === COURSE_DEFINITION_VERSION,
      selectTask: async ({ state, tasks: available }) => {
        let generated = await listUniversityTasks(workDir, TASKS);
        let combined = [...available, ...generated];
        const university = await advanceUniversity(workDir, await masterySnapshot(workDir, state, combined), TASKS);
        generated = await listUniversityTasks(workDir, TASKS);
        combined = [...available, ...generated];
        const unpark = new Set(university.courses.filter(course => course.retargetedAt).map(course => course.id));
        if (unpark.size && state.scheduler?.parkedTaskIds?.length) {
          state.scheduler.parkedTaskIds = state.scheduler.parkedTaskIds.filter(id => !unpark.has(id));
        }
        const selected = await selectCurriculumTask(workDir, state, combined);
        if (selected.university) {
          const lesson = selectRetainedLesson(
            state.lessons, selected.id, evidenceVersion,
            state.scheduler?.selectionCount ?? 0, true);
          if (lesson && (selected.revalidateLesson || lesson.evaluatorVersion !== evidenceVersion)) {
            const source = await readJson(path.join(workDir, 'runs', lesson.runId, 'source.json'), null);
            if (!source || hashFiles(source) !== lesson.sourceHash) {
              throw new Error(`Retained lesson ${lesson.runId} failed its source-hash check.`);
            }
            return {
              ...selected,
              initialFiles: source,
              revalidateInitial: true,
              retainedLessonRunId: lesson.runId,
            };
          }
        }
        if (selected.fileMode === 'styles') {
          return {
            ...selected,
            initialFiles: selected.initialFiles ?? getReference(selected.baseTaskId ?? selected.id),
          };
        }
        if (selected.fileMode === 'app') {
          const appFile = selected.appFile ?? 'App.jsx';
          return {
            ...selected,
            initialFiles: selected.initialFiles ?? {
              [appFile]: selected.university ? universityAppScaffold(appFile) : '',
              'styles.css': getReference(selected.baseTaskId ?? selected.id)['styles.css'],
            },
          };
        }
        return selected.qualityProfile && !selected.university
          ? { ...selected, fileMode: 'styles', initialFiles: getReference(selected.id) }
          : selected;
      },
      onProgress: result => console.log(`${new Date().toISOString()} ${result.taskId} ${result.passed ? 'PASS' : 'RETRY'} | attempts=${result.stats.attempts} examples=${result.lessonCount} | ${result.runId}`),
    }, {
      tasks, evaluate: evaluateCandidate, evaluatorVersion: evidenceVersion,
      documentation: createDocumentationReader(workDir, { offline: values['offline-docs'] }),
    });
  } finally {
    await dashboard?.close();
    process.removeListener('SIGINT', stop);
    process.removeListener('SIGTERM', stop);
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  main().catch(error => {
    console.error(`Frontend gym: ${error.message}`);
    process.exitCode = 1;
  });
}
