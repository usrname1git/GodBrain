import { randomUUID } from 'node:crypto';
import path from 'node:path';
import { cancelObjective, enqueueObjective, listObjectives } from './objectives.mjs';
import { readJson, writeJson } from './gym-core.mjs';
import { loadProjectCatalog, projectIds } from './project-assets.mjs';

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
    direction: 'Spacious editorial composition on near-black paper with light type and one copper accent on the button only. No second background.',
  },
  {
    id: 'product-led',
    title: 'Product-led interactive',
    direction: 'Tighter product panels on that same dark paper and light type. One copper button. No cyan and no teal.',
  },
  {
    id: 'enterprise-trust',
    title: 'Enterprise trust',
    direction: 'Calm comparison layout on the same dark paper and light type. Thin rules. No cream field and no floating navy panel.',
  },
  {
    id: 'event-experience',
    title: 'Event experience',
    direction: 'More air around the same dark paper and light type. One copper accent. The journey sections stay on that paper.',
  },
]);
const MAX_ALTERNATIVE_HISTORY = 10;
let transactionTail = Promise.resolve();

function retainVersionHistory(versions) {
  return versions.filter((version, index) =>
    index >= versions.length - MAX_ALTERNATIVE_HISTORY ||
    version.previewRunId ||
    (['delivered', 'delivered_limited'].includes(version.status) && version.assemblyRunIds?.length) ||
    version.alternatives?.some(item => item.status === 'ready' && item.runId));
}

function assertNoActiveProject(campaigns, brief, exceptId) {
  const duplicate = campaigns.items.find(campaign =>
    campaign.id !== exceptId &&
    ['planning', 'training', 'assembling', 'showcasing'].includes(campaign.status) &&
    campaign.brief.siteType === brief.siteType &&
    campaign.brief.name.trim().toLowerCase() === brief.name.trim().toLowerCase());
  if (duplicate) throw new Error(`An active campaign named "${brief.name}" already exists (${duplicate.id}).`);
}

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
  const projects = projectIds(input.projectIds);
  return {
    name: text(input.name, 'Project name', 120, true),
    siteType,
    brief: text(input.brief, 'Client brief', 3000, true),
    pages: text(input.pages, 'Pages', 1000),
    features,
    styleReference: text(input.styleReference, 'Style reference', 1200),
    brandNotes: text(input.brandNotes, 'Brand notes', 1600),
    ...(projects.length ? { projectIds: projects } : {}),
  };
}

function projectBrief(brief) {
  if (!brief.projectIds?.length) return '';
  return `Use the supplied projects prop for ${brief.projectIds.join(', ')}. Each project has id,title,description,url,sourceUrl,cover,images:[{id,url,width,height,description,captureKind}]. Render each cover as <img src={image.url}> from these props, not hardcoded paths or values. Do not fetch images or use CSS image URLs. Preserve the capture disclaimers.`;
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
    projectBrief(brief),
    `Site type: ${brief.siteType}.`,
    `Client brief: ${brief.brief}`,
    brief.pages ? `Pages or sections: ${brief.pages}` : '',
    brief.brandNotes ? `Brand direction: ${brief.brandNotes}` : '',
    brief.features.length ? `Requested capabilities: ${brief.features.join(', ')}.` : '',
    campaign.capabilities.length
      ? `Earlier capability checks: ${campaign.capabilities.map(item => item.title).join(', ')}.`
      : 'Build the requested website directly. Do not substitute training exercises for the client deliverable.',
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
    projectBrief(brief),
    `Client brief: ${brief.brief}`,
    brief.pages ? `Required pages or sections: ${brief.pages}` : '',
    brief.brandNotes ? `Brand direction: ${brief.brandNotes}` : '',
    'Preserve working navigation and interactions. Improve information hierarchy, realistic content, conversion flow, responsive behavior, keyboard access, error/empty states and visual consistency. Return a complete replacement for both files, but keep the implementation compact enough to fit the response budget.',
  ]);
}

export function alternativePrompt(campaign, variant, stage, retry = 0) {
  const brief = campaign.brief;
  if (brief.projectIds?.length) {
    return objectivePrompt([
      `Restyle the existing client site "${brief.name}" as "${variant.title}".`,
      projectBrief(brief), variant.direction,
      'Change only CSS; preserve the existing React structure, catalog-driven images, navigation and interactions. No CSS image URLs.',
    ]);
  }
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
  const repeatFile = path.join(workDir, 'repeat-campaign.json');
  const repeat = await readJson(repeatFile, null);
  if (repeat && !repeat.retiredAt) {
    const campaign = campaigns.items.find(item => item.id === (repeat.campaignId ?? repeat.previousCampaignId));
    const previous = campaign?.alternativeHistory?.filter(set =>
      ['alternatives_ready', 'alternatives_limited'].includes(set.status)).at(-1);
    if (campaign?.status === 'showcasing' && previous) {
      for (const variant of campaign.alternatives ?? []) {
        for (const id of [variant.appObjectiveId, variant.styleObjectiveId].filter(Boolean)) {
          await cancelObjective(workDir, id, 'Automatic client repetition retired; generation now requires an explicit request.');
        }
      }
      campaign.alternativeHistory.push({
        generation: campaign.alternativeGeneration, status: 'cancelled',
        archivedAt: new Date().toISOString(), alternatives: campaign.alternatives,
      });
      campaign.alternativeHistory = retainVersionHistory(campaign.alternativeHistory);
      campaign.alternatives = previous.alternatives;
      campaign.alternativeGeneration = previous.generation;
      campaign.status = previous.status;
      campaign.updatedAt = new Date().toISOString();
      campaign.lastError = null;
      changed = true;
    }
    if (changed) await writeJson(path.join(workDir, 'campaigns.json'), campaigns);
    await writeJson(repeatFile, {
      ...repeat, previousCampaignId: repeat.campaignId ?? repeat.previousCampaignId,
      campaignId: null, disabled: true, retiredAt: new Date().toISOString(),
    });
  }
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
              mode: campaign.brief.projectIds?.length ? 'explore' : 'qualify',
              title: `${campaign.brief.name}: ${variant.title} visual system${generation > 1 ? ` (rerun ${generation})` : ''}`,
              prompt: alternativePrompt(campaign, variant, 'styles', retry),
              styleReference: campaign.brief.styleReference,
              contractTaskId: campaign.brief.projectIds?.length ? undefined : 'event-platform-showcase-v1',
            }, trustedTasks, {
              stableKey,
              campaignId: campaign.id,
              campaignStage: 'alternative-styles',
              maxTokens: 4096,
              initialRunId: variant.appRunId ?? (campaign.brief.projectIds?.length ? campaign.previewRunId : null),
              templateTaskId: variant.appRunId || campaign.brief.projectIds?.length ? null : 'event-platform-showcase-v1',
              clientProjectIds: campaign.brief.projectIds,
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
      const complete = campaign.buildMode === 'website' ||
        (campaign.capabilities.length > 0 &&
          campaign.capabilities.every(item => ['passed', 'attempt_limit'].includes(item.outcome)));
      if (complete) {
        const stableKey = assemblyKey(campaign, 'shell');
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
            clientProjectIds: campaign.brief.projectIds,
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
    if (campaign.status === 'assembling') {
      const assembly = objectives.find(item =>
        item.id === campaign.assemblyObjectiveId);
      if (assembly && campaign.assemblyObjectiveId !== assembly.id) {
        campaign.assemblyObjectiveId = assembly.id;
        changed = true;
      }
      campaign.assemblyRunIds = assembly?.runIds ?? [];
      if (campaign.assemblyStage === 'polish' && assembly?.initialRunId && !campaign.previewRunId) {
        campaign.previewRunId = assembly.initialRunId;
        changed = true;
      }
      if (assembly?.outcome === 'passed') {
        campaign.previewRunId = assembly.runIds.at(-1);
        if (campaign.assemblyStage === 'shell' || campaign.assemblyStage === 'shell-recovery') {
          const initialRunId = assembly.runIds.at(-1);
          if (!initialRunId) throw new Error(`Passing assembly objective ${assembly.id} has no source run.`);
          const stableKey = assemblyKey(campaign, 'polish');
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
              clientProjectIds: campaign.brief.projectIds,
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
          const stableKey = assemblyKey(campaign, 'shell-recovery');
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
              clientProjectIds: campaign.brief.projectIds,
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
  if (brief.projectIds?.length) await loadProjectCatalog(workDir, brief.projectIds);
  return transaction(async () => {
    const campaigns = await readCampaigns(workDir);
    if (campaigns.version !== 1 || !Array.isArray(campaigns.items)) throw new Error('Campaign store is damaged.');
    if (campaigns.items.length >= MAX_CAMPAIGNS) {
      throw new Error(`Campaign capacity (${MAX_CAMPAIGNS}) reached; archive completed campaigns first.`);
    }
    assertNoActiveProject(campaigns, brief);
    const id = randomUUID().replaceAll('-', '').slice(0, 12);
    const campaign = {
      id,
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
      status: 'planning',
      buildMode: 'website',
      buildGeneration: 1,
      brief,
      capabilities: [],
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

function assemblyKey(campaign, stage) {
  const generation = campaign.buildGeneration == null ? '' : `:site-g${campaign.buildGeneration}`;
  return `campaign:${campaign.id}${generation}:assembly:${stage}-v2`;
}

export async function advanceCampaigns(workDir, trustedTasks) {
  return transaction(async () => {
    const campaigns = await readCampaigns(workDir);
    return reconcileCampaigns(workDir, campaigns, trustedTasks);
  });
}

export async function regenerateCampaign(workDir, campaignId, trustedTasks) {
  return transaction(async () => {
    const campaigns = await readCampaigns(workDir);
    const campaign = campaigns.items.find(item => item.id === campaignId);
    if (!campaign) throw new Error(`Unknown website ${campaignId}.`);
    if (!['delivered', 'delivered_limited', 'blocked', 'alternatives_ready', 'alternatives_limited'].includes(campaign.status)) {
      throw new Error('Wait for the current generation to finish before regenerating.');
    }
    assertNoActiveProject(campaigns, campaign.brief, campaign.id);
    campaign.buildHistory = retainVersionHistory([...(campaign.buildHistory ?? []), {
      generation: campaign.buildGeneration ?? 0, status: campaign.status,
      previewRunId: campaign.previewRunId ?? null,
      assemblyRunIds: campaign.assemblyRunIds ?? [],
      archivedAt: new Date().toISOString(),
    }]);
    if (campaign.alternatives?.length) {
      campaign.alternativeHistory = retainVersionHistory([...(campaign.alternativeHistory ?? []), {
        generation: campaign.alternativeGeneration, status: campaign.status,
        archivedAt: new Date().toISOString(), alternatives: campaign.alternatives,
      }]);
      campaign.alternatives = [];
    }
    campaign.buildMode = 'website';
    campaign.buildGeneration = (campaign.buildGeneration ?? 0) + 1;
    campaign.status = 'planning';
    campaign.capabilities = [];
    campaign.assemblyObjectiveId = null;
    campaign.assemblyRunIds = [];
    campaign.assemblyStage = null;
    campaign.previewRunId = null;
    campaign.deliveredAt = null;
    campaign.lastError = null;
    campaign.updatedAt = new Date().toISOString();
    await writeJson(path.join(workDir, 'campaigns.json'), campaigns);
    await reconcileCampaigns(workDir, campaigns, trustedTasks);
    return campaign;
  });
}

export async function requestCampaignAlternatives(workDir, campaignId, trustedTasks) {
  return transaction(async () => {
    const campaigns = await readCampaigns(workDir);
    const campaign = campaigns.items.find(item => item.id === campaignId);
    if (!campaign) throw new Error(`Unknown campaign ${campaignId}.`);
    if (campaign.brief.projectIds?.length && !campaign.previewRunId) {
      throw new Error('Project-image alternatives require an existing browser-checked site to restyle.');
    }
    const terminalWithoutAlternatives = ['blocked', 'delivered', 'delivered_limited'].includes(campaign.status);
    const terminalWithAlternatives = ['alternatives_ready', 'alternatives_limited'].includes(campaign.status);
    if ((!campaign.alternatives?.length && !terminalWithoutAlternatives) ||
        (campaign.alternatives?.length && !terminalWithAlternatives)) {
      throw new Error('Alternatives can be requested only after the primary campaign reaches a terminal result.');
    }
    assertNoActiveProject(campaigns, campaign.brief, campaign.id);
    if (campaign.alternatives) {
      const history = Array.isArray(campaign.alternativeHistory) ? campaign.alternativeHistory : [];
      history.push({
        generation: campaign.alternativeGeneration ?? 1,
        status: campaign.status,
        archivedAt: new Date().toISOString(),
        alternatives: campaign.alternatives,
      });
      campaign.alternativeHistory = retainVersionHistory(history);
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
