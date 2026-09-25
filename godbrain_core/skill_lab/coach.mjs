import { randomUUID } from 'node:crypto';
import { promises as fs } from 'node:fs';
import path from 'node:path';
import { cancelObjective, enqueueObjective, listObjectives } from './objectives.mjs';
import { readJson, writeJson } from './gym-core.mjs';

const SITE_TYPES = new Set([
  'business', 'storefront', 'portfolio', 'documentation',
  'saas-dashboard', 'booking', 'community', 'custom',
]);
const FEATURE_NAMES = new Set([
  'catalog', 'search-filter-sort', 'contact-form', 'registration',
  'account-settings', 'workflow', 'persistent-data', 'dialogs',
  'keyboard-accessibility', 'analytics', 'responsive-navigation',
]);
const MAX_CAMPAIGNS = 50;
const ALTERNATIVE_DIRECTIONS = Object.freeze([
  {
    id: 'nordic-editorial',
    title: 'Nordic editorial',
    direction: 'Spacious editorial composition on warm paper with near-black ink and one bronze accent. No second background.',
  },
  {
    id: 'product-led',
    title: 'Product-led interactive',
    direction: 'Tighter product panels on the same paper and ink as the hero. One ink button. No cyan and no teal.',
  },
  {
    id: 'enterprise-trust',
    title: 'Enterprise trust',
    direction: 'Calm comparison layout on the same paper as the hero. Thin rules, black ink. No floating navy panel.',
  },
  {
    id: 'event-experience',
    title: 'Event experience',
    direction: 'More air around the same paper and ink. One warm accent. The journey sections stay on that paper.',
  },
]);
const MAX_ALTERNATIVE_HISTORY = 10;
let transactionTail = Promise.resolve();

function transaction(action) {
  const current = transactionTail.then(action);
  transactionTail = current.catch(() => {});
  return current;
}

function text(value, name, limit, required = false) {
  const result = String(value ?? '').trim();
  if (required && !result) throw new Error(`${name} is required.`);
  if (result.length > limit || result.includes('\0')) throw new Error(`${name} is too long or invalid.`);
  return result;
}

function objectivePrompt(parts) {
  const value = parts.filter(Boolean).join('\n');
  return value.length <= 1200 ? value : `${value.slice(0, 1186)}\n[truncated]`;
}

export function validateClientBrief(input) {
  if (!input || Array.isArray(input) || typeof input !== 'object') throw new Error('Client brief must be an object.');
  const siteType = String(input.siteType ?? '').trim().toLowerCase();
  if (!SITE_TYPES.has(siteType)) throw new Error('Unknown site type.');
  const features = [...new Set(Array.isArray(input.features) ? input.features.map(String) : [])];
  if (features.some(feature => !FEATURE_NAMES.has(feature))) throw new Error('Unknown client feature.');
  if (features.length > FEATURE_NAMES.size) throw new Error('Too many client features.');
  return {
    name: text(input.name, 'Project name', 120, true),
    siteType,
    brief: text(input.brief, 'Client brief', 3000, true),
    pages: text(input.pages, 'Pages', 1000),
    features,
    styleReference: text(input.styleReference, 'Style reference', 1200),
    brandNotes: text(input.brandNotes, 'Brand notes', 1600),
  };
}

function capabilityPlan(brief) {
  const ids = new Set(['keyboard-tabs-dialog-v1']);
  const add = id => ids.add(id);
  if (brief.siteType === 'storefront' || brief.siteType === 'documentation') add('catalog-search-sort-v1');
  if (brief.siteType === 'saas-dashboard' || brief.siteType === 'community') {
    add('task-list-productivity-v1');
    add('settings-persistence-v1');
  }
  if (brief.siteType === 'booking') {
    add('registration-validation-v1');
    add('settings-persistence-v1');
  }
  if (['business', 'portfolio', 'community'].includes(brief.siteType)) add('registration-validation-v1');
  for (const feature of brief.features) {
    if (['catalog', 'search-filter-sort', 'analytics'].includes(feature)) add('catalog-search-sort-v1');
    if (['contact-form', 'registration'].includes(feature)) add('registration-validation-v1');
    if (['account-settings', 'persistent-data'].includes(feature)) add('settings-persistence-v1');
    if (feature === 'workflow') add('task-list-productivity-v1');
    if (['dialogs', 'keyboard-accessibility', 'responsive-navigation'].includes(feature)) add('keyboard-tabs-dialog-v1');
  }
  return [...ids];
}

function campaignPrompt(brief, contractTitle) {
  return objectivePrompt([
    `Client project: ${brief.name}`,
    `Site type: ${brief.siteType}`,
    `Client request: ${brief.brief}`,
    brief.pages ? `Requested pages: ${brief.pages}` : '',
    brief.brandNotes ? `Brand direction: ${brief.brandNotes}` : '',
    `Practice and qualify the "${contractTitle}" capability as a polished component suitable for this client project. Preserve every functional requirement in the trusted contract while adapting the visual language to the client brief.`,
  ]);
}

function assemblyShellPrompt(campaign) {
  const brief = campaign.brief;
  const limitations = campaign.capabilities.filter(item => item.outcome !== 'passed');
  return objectivePrompt([
    `Build a compact but complete first-pass client frontend "${brief.name}".`,
    `Site type: ${brief.siteType}.`,
    `Client brief: ${brief.brief}`,
    brief.pages ? `Pages or sections: ${brief.pages}` : '',
    brief.brandNotes ? `Brand direction: ${brief.brandNotes}` : '',
    brief.features.length ? `Requested capabilities: ${brief.features.join(', ')}.` : '',
    `Qualified practice completed for: ${campaign.capabilities.map(item => item.title).join(', ')}.`,
    limitations.length
      ? `Training limitations to handle carefully: ${limitations.map(item => item.title).join(', ')} reached the attempt limit rather than a passing verdict.`
      : '',
    'Create one coherent responsive React frontend, not disconnected demos. Include every requested page as a navigable section, but keep text and source deliberately compact so the complete JSON response fits. Prioritize structure, navigation, interaction and responsive layout over exhaustive copy.',
  ]);
}

function assemblyPolishPrompt(campaign) {
  const brief = campaign.brief;
  return objectivePrompt([
    `Polish and integrate the existing source for "${brief.name}" without replacing it with an unrelated design.`,
    `Client brief: ${brief.brief}`,
    brief.pages ? `Required pages or sections: ${brief.pages}` : '',
    brief.brandNotes ? `Brand direction: ${brief.brandNotes}` : '',
    'Preserve working navigation and interactions. Improve information hierarchy, realistic content, conversion flow, responsive behavior, keyboard access, error/empty states and visual consistency. Return a complete replacement for both files, but keep the implementation compact enough to fit the response budget.',
  ]);
}

export function alternativePrompt(campaign, variant, stage, retry = 0) {
  const brief = campaign.brief;
  const common = [
    `Create the "${variant.title}" alternative for ${brief.name}.`,
    variant.direction,
  ];
  if (stage === 'app') {
    common.push(
      'This is Trippus, a Scandinavian B2B event platform. Eventus is one assistant, not the whole product.',
      'Primary actions: Book a demo, Try it yourself, Explore the platform, Compare packages.',
      'Use realistic demonstrative content only. Never invent metrics, certifications, guarantees, or prices.',
      'Build the semantic React structure and the trusted interactions. Keep JSX compact. CSS is supplied separately.',
    );
  } else {
    common.push(
      'Write only CSS. A hero photo means the whole page is dark, like Northline: near-black paper, light type, one copper accent on the button only.',
      'One photo: url("/media/event-a.jpg"), url("/media/event-b.jpg"), or url("/media/event-c.jpg") on .hero, with a dark scrim. No other url().',
      'Header, body, .tinted, .dark, cards, and footer use that same dark paper. Do not drop to cream, ivory, or a bleached field under the photo.',
      'Set :root and every [data-theme] so --paper, --header, --tint, and --footer are the same dark color. No light teal, mint, sage, or pale aqua. Two fonts. One type scale.',
      `Change spacing so "${variant.title}" is recognizable. The product claim stays huge.`,
    );
    if (retry) {
      common.push('The last pass put a cream page under the dark photo. Make --paper dark and the type light, including .dark and the footer.');
    }
  }
  return objectivePrompt(common);
}

function freshAlternatives() {
  return ALTERNATIVE_DIRECTIONS.map(direction => ({
    ...direction,
    status: 'planning',
    appObjectiveId: null,
    appRunId: null,
    styleObjectiveId: null,
    styleRetry: 0,
    runId: null,
    sourceHash: null,
    visualFingerprint: null,
    completedAt: null,
    lastError: null,
  }));
}

async function readCampaigns(workDir) {
  return await readJson(path.join(workDir, 'campaigns.json'), { version: 1, items: [] });
}

export async function listCampaigns(workDir) {
  const value = await readCampaigns(workDir);
  return value.items ?? [];
}

async function reconcileCampaigns(workDir, campaigns, trustedTasks) {
  const objectives = await listObjectives(workDir);
  let changed = false;
  const ordered = [...(campaigns.items ?? [])].sort((a, b) => new Date(a.createdAt) - new Date(b.createdAt));
  for (const campaign of ordered) {
    const duplicate = ordered.find(candidate =>
      candidate !== campaign &&
      new Date(candidate.createdAt) > new Date(campaign.createdAt) &&
      new Date(candidate.createdAt) - new Date(campaign.createdAt) <= 30 * 60 * 1000 &&
      candidate.brief.siteType === campaign.brief.siteType &&
      candidate.brief.name.trim().toLowerCase() === campaign.brief.name.trim().toLowerCase());
    if (duplicate && campaign.status === 'blocked') {
      campaign.status = 'superseded';
      campaign.updatedAt = new Date().toISOString();
      campaign.lastError = `Superseded by accidental duplicate campaign ${duplicate.id}.`;
      changed = true;
    }
  }
  for (const campaign of campaigns.items ?? []) {
    if (campaign.status === 'showcasing') {
      for (const variant of campaign.alternatives ?? []) {
        if (variant.status === 'planning') {
          variant.status = 'styling';
          changed = true;
        }
        if (variant.status === 'building-structure') {
          const app = objectives.find(item => item.id === variant.appObjectiveId);
          if (app?.outcome === 'passed') {
            variant.appRunId = app.runIds.at(-1);
            variant.status = 'styling';
            changed = true;
          } else {
            await cancelObjective(workDir, variant.appObjectiveId,
              'Replaced by the trusted interaction scaffold plus bounded visual-system training.');
            variant.appObjectiveId = null;
            variant.status = 'styling';
            variant.lastError = 'Migrated from oversized JSX generation to a trusted interaction scaffold.';
            changed = true;
          }
        }
        if (variant.status === 'styling') {
          const retry = variant.styleRetry ?? 0;
          const generation = campaign.alternativeGeneration ?? 1;
          const stableKey = `campaign:${campaign.id}:alternative:${variant.id}:set-v${generation}:styles-v${retry + 1}`;
          let styles = objectives.find(item => item.stableKey === stableKey);
          if (!styles) {
            styles = await enqueueObjective(workDir, {
              mode: 'qualify',
              title: `${campaign.brief.name}: ${variant.title} visual system${generation > 1 ? ` (rerun ${generation})` : ''}`,
              prompt: alternativePrompt(campaign, variant, 'styles', retry),
              styleReference: campaign.brief.styleReference,
              contractTaskId: 'event-platform-showcase-v1',
            }, trustedTasks, {
              stableKey,
              campaignId: campaign.id,
              campaignStage: 'alternative-styles',
              maxTokens: 4096,
              initialRunId: variant.appRunId ?? null,
              templateTaskId: variant.appRunId ? null : 'event-platform-showcase-v1',
              fileMode: 'styles',
              evaluationProfile: 'full',
              variantId: variant.id,
            });
            objectives.push(styles);
          }
          variant.styleObjectiveId = styles.id;
          variant.status = 'qualifying';
          changed = true;
        }
        if (variant.status === 'qualifying') {
          const styles = objectives.find(item => item.id === variant.styleObjectiveId);
          if (styles?.outcome === 'passed') {
            const runId = styles.runIds.at(-1);
            const receipt = await readJson(path.join(workDir, 'runs', runId, 'receipt.json'), null);
            const visualFingerprint = receipt?.evidence?.find(item => item.visualFingerprint)?.visualFingerprint ?? null;
            const duplicate = (campaign.alternatives ?? []).some(other =>
              other !== variant && other.status === 'ready' &&
              (other.sourceHash === receipt?.sourceHash ||
               (visualFingerprint && other.visualFingerprint === visualFingerprint)));
            if (duplicate && (variant.styleRetry ?? 0) < 1) {
              variant.styleRetry = (variant.styleRetry ?? 0) + 1;
              variant.status = 'styling';
              variant.lastError = 'The first passing style was not materially distinct; restyling once.';
            } else if (!receipt?.sourceHash || !visualFingerprint) {
              variant.status = 'blocked';
              variant.lastError = 'Passing evidence lacked the required source or visual fingerprint.';
            } else {
              variant.status = 'ready';
              variant.runId = runId;
              variant.sourceHash = receipt.sourceHash;
              variant.visualFingerprint = visualFingerprint;
              variant.completedAt = new Date().toISOString();
              variant.lastError = null;
            }
            changed = true;
          } else if (styles?.outcome === 'attempt_limit') {
            if ((variant.styleRetry ?? 0) < 1) {
              variant.styleRetry = (variant.styleRetry ?? 0) + 1;
              variant.status = 'styling';
              variant.lastError = 'The visual stage reached its first attempt limit; replanning the style once.';
            } else {
              variant.status = 'blocked';
              variant.lastError = 'The visual stage reached its bounded recovery limit.';
            }
            changed = true;
          }
        }
      }
      const variants = campaign.alternatives ?? [];
      if (variants.length && variants.every(item => ['ready', 'blocked'].includes(item.status))) {
        campaign.status = variants.every(item => item.status === 'ready') ? 'alternatives_ready' : 'alternatives_limited';
        campaign.updatedAt = new Date().toISOString();
        changed = true;
      }
      continue;
    }
    if (campaign.status === 'planning') {
      for (const capability of campaign.capabilities) {
        let objective = objectives.find(item => item.stableKey === capability.stableKey);
        if (!objective) {
          objective = await enqueueObjective(workDir, {
            mode: 'qualify',
            title: `${campaign.brief.name}: ${capability.title}`,
            prompt: campaignPrompt(campaign.brief, capability.title),
            styleReference: campaign.brief.styleReference,
            contractTaskId: capability.contractTaskId,
          }, trustedTasks, {
            stableKey: capability.stableKey,
            campaignId: campaign.id,
            campaignStage: 'capability',
          });
          objectives.push(objective);
        }
        capability.objectiveId = objective.id;
      }
      campaign.status = 'training';
      campaign.updatedAt = new Date().toISOString();
      changed = true;
    }
    if (campaign.status === 'training') {
      for (const capability of campaign.capabilities) {
        const objective = objectives.find(item => item.id === capability.objectiveId);
        const outcome = objective?.outcome ?? null;
        if (capability.outcome !== outcome) {
          capability.outcome = outcome;
          campaign.updatedAt = new Date().toISOString();
          changed = true;
        }
      }
      const complete = campaign.capabilities.length > 0 &&
        campaign.capabilities.every(item => ['passed', 'attempt_limit'].includes(item.outcome));
      if (complete) {
        const stableKey = `campaign:${campaign.id}:assembly:shell-v2`;
        let assembly = objectives.find(item => item.stableKey === stableKey);
        if (!assembly) {
          assembly = await enqueueObjective(workDir, {
            mode: 'explore',
            title: `${campaign.brief.name}: site shell`,
            prompt: assemblyShellPrompt(campaign),
            styleReference: campaign.brief.styleReference,
          }, trustedTasks, {
            stableKey,
            campaignId: campaign.id,
            campaignStage: 'assembly-shell',
            maxTokens: 4096,
          });
          objectives.push(assembly);
        }
        campaign.assemblyObjectiveId = assembly.id;
        campaign.assemblyStage = 'shell';
        campaign.status = 'assembling';
        campaign.updatedAt = new Date().toISOString();
        changed = true;
      }
    }
    if (campaign.status === 'blocked' && !campaign.recoveryStartedAt) {
      const stableKey = `campaign:${campaign.id}:assembly:shell-v2`;
      let assembly = objectives.find(item => item.stableKey === stableKey);
      if (!assembly) {
        assembly = await enqueueObjective(workDir, {
          mode: 'explore',
          title: `${campaign.brief.name}: recovered site shell`,
          prompt: assemblyShellPrompt(campaign),
          styleReference: campaign.brief.styleReference,
        }, trustedTasks, {
          stableKey,
          campaignId: campaign.id,
          campaignStage: 'assembly-shell',
          maxTokens: 4096,
        });
        objectives.push(assembly);
      }
      campaign.assemblyObjectiveId = assembly.id;
      campaign.assemblyStage = 'shell';
      campaign.status = 'assembling';
      campaign.recoveryStartedAt = new Date().toISOString();
      campaign.updatedAt = campaign.recoveryStartedAt;
      campaign.lastError = null;
      changed = true;
    }
    if (campaign.status === 'assembling') {
      const assembly = objectives.find(item =>
        item.id === campaign.assemblyObjectiveId);
      if (assembly && campaign.assemblyObjectiveId !== assembly.id) {
        campaign.assemblyObjectiveId = assembly.id;
        changed = true;
      }
      campaign.assemblyRunIds = assembly?.runIds ?? [];
      if (assembly?.outcome === 'passed') {
        if (campaign.assemblyStage === 'shell' || campaign.assemblyStage === 'shell-recovery') {
          const initialRunId = assembly.runIds.at(-1);
          if (!initialRunId) throw new Error(`Passing assembly objective ${assembly.id} has no source run.`);
          const stableKey = `campaign:${campaign.id}:assembly:polish-v2`;
          let polish = objectives.find(item => item.stableKey === stableKey);
          if (!polish) {
            polish = await enqueueObjective(workDir, {
              mode: 'explore',
              title: `${campaign.brief.name}: integration and polish`,
              prompt: assemblyPolishPrompt(campaign),
              styleReference: campaign.brief.styleReference,
            }, trustedTasks, {
              stableKey,
              campaignId: campaign.id,
              campaignStage: 'assembly-polish',
              maxTokens: 4096,
              initialRunId,
            });
            objectives.push(polish);
          }
          campaign.assemblyObjectiveId = polish.id;
          campaign.assemblyStage = 'polish';
          campaign.updatedAt = new Date().toISOString();
          changed = true;
        } else {
          campaign.status = 'delivered';
          campaign.deliveredAt = new Date().toISOString();
          campaign.updatedAt = campaign.deliveredAt;
          changed = true;
        }
      } else if (assembly?.outcome === 'attempt_limit') {
        if (campaign.assemblyStage === 'shell') {
          const stableKey = `campaign:${campaign.id}:assembly:shell-recovery-v2`;
          let recovery = objectives.find(item => item.stableKey === stableKey);
          if (!recovery) {
            recovery = await enqueueObjective(workDir, {
              mode: 'explore',
              title: `${campaign.brief.name}: compact shell recovery`,
              prompt: assemblyShellPrompt(campaign),
              styleReference: campaign.brief.styleReference,
            }, trustedTasks, {
              stableKey,
              campaignId: campaign.id,
              campaignStage: 'assembly-shell-recovery',
              maxTokens: 4096,
            });
            objectives.push(recovery);
          }
          campaign.assemblyObjectiveId = recovery.id;
          campaign.assemblyStage = 'shell-recovery';
          campaign.updatedAt = new Date().toISOString();
          changed = true;
        } else if (campaign.assemblyStage === 'polish') {
          campaign.status = 'delivered_limited';
          campaign.deliveredAt = new Date().toISOString();
          campaign.updatedAt = campaign.deliveredAt;
          campaign.lastError = 'The browser-qualified site shell is available, but the optional polish stage reached its attempt limit.';
          changed = true;
        } else {
          campaign.status = 'blocked';
          campaign.updatedAt = new Date().toISOString();
          campaign.lastError = 'Staged site shell assembly reached its recovery limit without a passing browser verdict.';
          changed = true;
        }
      }
    }
  }
  if (changed) await writeJson(path.join(workDir, 'campaigns.json'), campaigns);
  return campaigns.items ?? [];
}

export async function createCampaign(workDir, input, trustedTasks) {
  const brief = validateClientBrief(input);
  return transaction(async () => {
    const campaigns = await readCampaigns(workDir);
    if (campaigns.version !== 1 || !Array.isArray(campaigns.items)) throw new Error('Campaign store is damaged.');
    if (campaigns.items.length >= MAX_CAMPAIGNS) {
      throw new Error(`Campaign capacity (${MAX_CAMPAIGNS}) reached; archive completed campaigns first.`);
    }
    const duplicate = campaigns.items.find(campaign =>
      ['planning', 'training', 'assembling'].includes(campaign.status) &&
      campaign.brief.siteType === brief.siteType &&
      campaign.brief.name.trim().toLowerCase() === brief.name.trim().toLowerCase());
    if (duplicate) throw new Error(`An active campaign named "${brief.name}" already exists (${duplicate.id}).`);
    const id = randomUUID().replaceAll('-', '').slice(0, 12);
    const capabilities = capabilityPlan(brief).map(contractTaskId => {
      const contract = trustedTasks.find(task => task.id === contractTaskId);
      if (!contract) throw new Error(`Missing trusted coach contract: ${contractTaskId}`);
      return {
        contractTaskId,
        title: contract.title,
        stableKey: `campaign:${id}:capability:${contractTaskId}`,
        objectiveId: null,
        outcome: null,
      };
    });
    const campaign = {
      id,
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
      status: 'planning',
      brief,
      capabilities,
      assemblyObjectiveId: null,
      assemblyStage: null,
      assemblyRunIds: [],
      deliveredAt: null,
      lastError: null,
    };
    campaigns.items.push(campaign);
    await writeJson(path.join(workDir, 'campaigns.json'), campaigns);
    await reconcileCampaigns(workDir, campaigns, trustedTasks);
    return campaign;
  });
}

export async function advanceCampaigns(workDir, trustedTasks) {
  return transaction(async () => {
    const campaigns = await readCampaigns(workDir);
    return reconcileCampaigns(workDir, campaigns, trustedTasks);
  });
}

async function saveReadyAlternatives(workDir, campaign, saveDir) {
  const generation = campaign.alternativeGeneration ?? 1;
  for (const variant of campaign.alternatives ?? []) {
    if (variant.status !== 'ready' || !variant.runId) continue;
    const folder = path.join(saveDir, `${campaign.id}-g${generation}-${variant.id}`);
    try {
      await fs.access(path.join(folder, 'source.json'));
      continue;
    } catch { /* not saved yet */ }
    await fs.mkdir(folder, { recursive: true });
    const runDir = path.join(workDir, 'runs', variant.runId);
    const sourcePath = path.join(runDir, 'source.json');
    try {
      const source = await readJson(sourcePath, {});
      for (const [name, text] of Object.entries(source)) {
        if (typeof text !== 'string') continue;
        await fs.writeFile(path.join(folder, name.replace(/[\\/]/g, '_')), text);
      }
      await fs.copyFile(sourcePath, path.join(folder, 'source.json'));
    } catch { /* source missing */ }
    for (const shot of ['practice/desktop.png', 'practice/mobile.png']) {
      try {
        await fs.copyFile(path.join(runDir, shot), path.join(folder, shot.replace('/', '-')));
      } catch { /* screenshot missing */ }
    }
  }
}

// repeat-campaign.json keeps one finished brief generating another set of four
// until the file is removed or training is paused.
export async function continueRepeatedCampaign(workDir, trustedTasks) {
  const marker = await readJson(path.join(workDir, 'repeat-campaign.json'), null);
  const campaignId = marker?.campaignId;
  if (!campaignId) return null;
  const campaigns = await readCampaigns(workDir);
  const campaign = (campaigns.items ?? []).find(item => item.id === campaignId);
  if (!campaign || !['alternatives_ready', 'alternatives_limited'].includes(campaign.status)) {
    return null;
  }
  const saveDir = marker.saveDir || 'C:\\nvme\\godbrain-sites\\trippus';
  await saveReadyAlternatives(workDir, campaign, saveDir);
  console.log(`Repeat campaign ${campaign.brief?.name || campaignId}: generation ${campaign.alternativeGeneration ?? 1} saved, starting the next four.`);
  return requestCampaignAlternatives(workDir, campaignId, trustedTasks);
}

export async function requestCampaignAlternatives(workDir, campaignId, trustedTasks) {
  return transaction(async () => {
    const campaigns = await readCampaigns(workDir);
    const campaign = campaigns.items.find(item => item.id === campaignId);
    if (!campaign) throw new Error(`Unknown campaign ${campaignId}.`);
    const terminalWithoutAlternatives = ['blocked', 'delivered', 'delivered_limited'].includes(campaign.status);
    const terminalWithAlternatives = ['alternatives_ready', 'alternatives_limited'].includes(campaign.status);
    if ((!campaign.alternatives && !terminalWithoutAlternatives) ||
        (campaign.alternatives && !terminalWithAlternatives)) {
      throw new Error('Alternatives can be requested only after the primary campaign reaches a terminal result.');
    }
    if (campaign.alternatives) {
      const history = Array.isArray(campaign.alternativeHistory) ? campaign.alternativeHistory : [];
      history.push({
        generation: campaign.alternativeGeneration ?? 1,
        status: campaign.status,
        archivedAt: new Date().toISOString(),
        alternatives: campaign.alternatives,
      });
      campaign.alternativeHistory = history.slice(-MAX_ALTERNATIVE_HISTORY);
      campaign.alternativeGeneration = (campaign.alternativeGeneration ?? 1) + 1;
    } else {
      campaign.alternativeGeneration = 1;
    }
    campaign.alternatives = freshAlternatives();
    campaign.status = 'showcasing';
    campaign.updatedAt = new Date().toISOString();
    campaign.lastError = null;
    await writeJson(path.join(workDir, 'campaigns.json'), campaigns);
    await reconcileCampaigns(workDir, campaigns, trustedTasks);
    return campaign;
  });
}
