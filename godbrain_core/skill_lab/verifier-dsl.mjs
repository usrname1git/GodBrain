const FILE_MODES = new Set(['both', 'app', 'styles']);
const APP_FILES = new Set(['App.jsx', 'App.tsx']);
const SOURCE_RULES = new Set([
  'typescript-component',
  'react-state',
  'semantic-layout',
  'responsive-styles',
  'form-validation',
]);

function exactKeys(value, allowed) {
  return Object.keys(value).every(key => allowed.has(key));
}

export function validateVerifierSpec(input, trustedTasks) {
  if (!input || Array.isArray(input) || typeof input !== 'object') {
    throw new Error('Verifier specification must be an object.');
  }
  const allowed = new Set([
    'version', 'contractTaskId', 'fileMode', 'appFile', 'evaluationProfile',
    'sourceRules', 'maxTokens',
  ]);
  if (!exactKeys(input, allowed) || input.version !== 1) {
    throw new Error('Unsupported verifier specification.');
  }
  if (!trustedTasks.some(task => task.id === input.contractTaskId)) {
    throw new Error(`Generated course references unknown trusted contract ${input.contractTaskId}.`);
  }
  if (!FILE_MODES.has(input.fileMode) || !APP_FILES.has(input.appFile)) {
    throw new Error('Generated course has an invalid file mode or application file.');
  }
  if (input.fileMode === 'styles' && input.appFile !== 'App.jsx') {
    throw new Error('Styles-only courses must use the trusted JSX reference application.');
  }
  if (!['full', 'structure-draft'].includes(input.evaluationProfile)) {
    throw new Error('Generated course has an invalid evaluation profile.');
  }
  if (!Array.isArray(input.sourceRules) ||
      input.sourceRules.some(rule => !SOURCE_RULES.has(rule)) ||
      new Set(input.sourceRules).size !== input.sourceRules.length) {
    throw new Error('Generated course contains unsupported source rules.');
  }
  if (!Number.isSafeInteger(input.maxTokens) || input.maxTokens < 1200 || input.maxTokens > 4096) {
    throw new Error('Generated course token budget is out of range.');
  }
  return {
    version: 1,
    contractTaskId: input.contractTaskId,
    fileMode: input.fileMode,
    appFile: input.appFile,
    evaluationProfile: input.evaluationProfile,
    sourceRules: [...input.sourceRules],
    maxTokens: input.maxTokens,
  };
}

export function validateGeneratedSource(task, files) {
  const spec = task.verifierSpec;
  if (!spec) return null;
  const app = files?.[spec.appFile] ?? '';
  const css = files?.['styles.css'] ?? '';
  for (const rule of spec.sourceRules) {
    if (rule === 'typescript-component') {
      if (spec.appFile !== 'App.tsx' || !/\b(?:interface|type)\s+\w*Props\b/.test(app)) {
        return 'The TypeScript course requires an explicit props interface or type in App.tsx.';
      }
      if (/\bas\s+(?:any|unknown)\b|:\s*any\b/.test(app)) {
        return 'The TypeScript course rejects any and unknown type escapes.';
      }
    } else if (rule === 'react-state' && !/\buse(?:State|Reducer)(?:\s*<[^(\r\n]{1,200}>)?\s*\(/.test(app)) {
      return 'The course requires real React state through useState or useReducer.';
    } else if (rule === 'semantic-layout' && !/<header\b[\s\S]*<main\b[\s\S]*<footer\b/i.test(app)) {
      return 'The course requires semantic header, main, and footer landmarks.';
    } else if (rule === 'responsive-styles' && !/@(?:media|container)\b/i.test(css)) {
      return 'The course requires an explicit responsive CSS breakpoint or container query.';
    } else if (rule === 'form-validation' &&
        (!/<form\b/i.test(app) || !/aria-invalid/i.test(app))) {
      return 'The course requires a real form with accessible invalid-state reporting.';
    }
  }
  return null;
}
