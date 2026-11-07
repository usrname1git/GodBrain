'use strict';

const shelves = [
  {id: 'sre', title: 'SRE Library', description: 'The canonical technical manual, with a separate view of candidates awaiting judgment.'},
  {id: 'research', title: 'Research', description: 'Working findings and open questions. Useful continuity, not verified instructions.'},
  {id: 'evaluations', title: 'Model Evaluations', description: 'Answer assessments retained in Research, independently of admission to the SRE manual.'},
  {id: 'discussion', title: 'Discussions', description: 'Work conversations and decisions, separate from verified knowledge.'},
  {id: 'sources', title: 'Sources', description: 'Declared evidence references from loaded records. Not a full raw-vault editor.'},
  {id: 'personal', title: 'Personal', description: 'Private working notes, isolated from technical recall and assistant context.'},
  {id: 'environment', title: 'Environment', description: 'The bounded host/capability map. A stored map grants neither authority nor current readiness.'},
];
const $ = id => document.getElementById(id);
const utf8 = new TextEncoder();
const state = {
  shelf: 'sre', records: [], graph: [], links: [], selected: null, query: '', filter: 'all',
  view: matchMedia('(max-width: 760px)').matches ? 'list' : 'map', tab: 'record',
  loading: false, error: '', notice: '', scale: 1, x: 0, y: 0, mapHeight: 720, page: 0,
};
let loadSerial = 0;
let selectionSerial = 0;
let toastTimer;
let drag;
let reviewRecord;
let reviewOriginalContent;
let lastReply;
let pendingPost;
let chatBusy = false;
const activity = new Map();
const statuses = new Set(['verified', 'candidate', 'rejected', 'stale']);

function element(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}
function svg(tag, attributes, text) {
  const node = document.createElementNS('http://www.w3.org/2000/svg', tag);
  for (const [name, value] of Object.entries(attributes)) node.setAttribute(name, value);
  if (text !== undefined) node.textContent = text;
  return node;
}
function assert(ok, message) { if (!ok) throw new Error(message); }
function token() { return sessionStorage.getItem('godbrain_write_token') || ''; }
function requireToken() {
  if (token()) return;
  if (!$('auth-dialog').open) $('auth-dialog').showModal();
  throw new Error('Protected shelves and writes require your configured API token.');
}
function notify(message) {
  $('toast').textContent = message;
  $('toast').hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { $('toast').hidden = true; }, 6500);
}
async function api(path, options = {}) {
  if (options.auth) requireToken();
  const headers = {'Content-Type': 'application/json'};
  if (token()) headers.Authorization = 'Bearer ' + token();
  const response = await fetch(path, {
    method: options.body === undefined ? 'GET' : 'POST', headers,
    body: options.body === undefined ? undefined : JSON.stringify(options.body),
    signal: options.signal,
  });
  let data;
  try { data = await response.json(); } catch { throw new Error(`${path}: invalid JSON response (HTTP ${response.status}).`); }
  if (!response.ok || data.error) {
    if (response.status === 401 || response.status === 403) sessionStorage.removeItem('godbrain_write_token');
    throw new Error(data.error || data.response || `${path}: HTTP ${response.status}`);
  }
  return data;
}
function currentShelf() { return shelves.find(shelf => shelf.id === state.shelf); }
function selectedRecord() { return state.records.find(record => record.id === state.selected); }
function visibleRecords() {
  const query = state.query.trim().toLowerCase();
  return state.records.filter(record =>
    (state.filter === 'all' || state.filter === 'verified' && record.status === 'verified' && !record.readError ||
      state.filter === 'review' && record.status === 'candidate') &&
    (!query || [record.title, record.summary, record.type].join(' ').toLowerCase().includes(query)));
}
function statusLabel(record) {
  if (record.readError) return 'Unread / status not confirmed';
  if (record.kind === 'working') return record.evaluation ? 'Evaluation / untrusted' : 'Working / untrusted';
  if (record.kind === 'environment') return 'Bounded / untrusted reference';
  if (record.kind === 'source') return 'Declared reference';
  return {verified: 'Verified record', candidate: 'Candidate / not verified', stale: 'Stale evidence', rejected: 'Rejected'}[record.status];
}
function graphRecords(data) {
  assert(Array.isArray(data.nodes) && Array.isArray(data.links) && data.nodes.length <= 80, 'Invalid canonical graph envelope.');
  const seen = new Set();
  const result = data.nodes.map(node => {
    assert(typeof node.id === 'string' && /^(?:[a-f0-9]{24}|[a-f0-9]{64})$/.test(node.id) && !seen.has(node.id) &&
      typeof node.stable_id === 'string' && /^[a-f0-9]{64}$/.test(node.stable_id) &&
      typeof node.title === 'string' && typeof node.group === 'string' && statuses.has(node.status), 'Invalid canonical graph record.');
    seen.add(node.id);
    return {id: node.id, stableId: node.stable_id, title: node.title, type: node.type || 'Canonical record',
      summary: node.group || 'Technical record', sector: node.group, status: node.status, kind: 'canonical', content: null, sources: []};
  }).filter(record => record.sector.toLowerCase() !== 'personal');
  return result;
}
function workingRecords(data, scope) {
  assert(data.schema_version === 'working-shelf-v1' && data.status === 'ok' && data.trust === 'untrusted' &&
    data.promoted === false && Array.isArray(data.records) && data.records.length <= 20, 'Invalid working-shelf envelope.');
  const seen = new Set();
  return data.records.map(row => {
    assert(row.scope === scope && row.trust === 'untrusted' && typeof row._id === 'string' &&
      /^[a-f0-9]{64}$/.test(row._id) && !seen.has(row._id) && typeof row.text === 'string' &&
      Array.isArray(row.sources) && row.sources.every(source => typeof source === 'string'), 'Invalid or cross-scope working record.');
    seen.add(row._id);
    const title = row.title || row.text.split('\n')[0].slice(0, 100) || 'Discussion record';
    const evaluation = /^model[- ]evaluation\b/i.test(title);
    return {id: row._id, title, type: evaluation ? 'Model evaluation' : 'Working record', summary: row.text.slice(0, 170),
      status: 'candidate', kind: 'working', scope, evaluation, content: row.text, sources: row.sources,
      created: row.created_at || row.at || '', sourceHash: row.source_hash};
  });
}
async function readWorking(shelf, scope = 'technical', query = '') {
  return api('/api/shelf', {auth: true, body: {action: 'read', shelf, scope, query, limit: 20}});
}
function renderShelves() {
  $('shelves').replaceChildren(...shelves.map(shelf => {
    const button = element('button', 'shelf-button');
    button.type = 'button';
    button.dataset.shelf = shelf.id;
    if (state.shelf === shelf.id) button.setAttribute('aria-current', 'page');
    button.append(element('span', 'shelf-dot'), element('span', '', shelf.title));
    if (state.shelf === shelf.id && !state.loading && !state.error) button.append(element('span', 'shelf-count', String(state.records.length)));
    button.addEventListener('click', () => switchShelf(shelf.id));
    return button;
  }));
}
async function switchShelf(id) {
  state.shelf = id;
  state.query = '';
  state.filter = 'all';
  state.page = 0;
  state.tab = 'record';
  $('search').value = '';
  $('status-filter').value = state.filter;
  await loadShelf();
}
async function loadShelf(serverQuery = '') {
  const serial = ++loadSerial;
  selectionSerial++;
  state.loading = true;
  state.error = '';
  state.records = [];
  state.selected = null;
  render();
  try {
    let records;
    let notice;
    if (state.shelf === 'sre') {
      const data = await api('/api/graph?limit=80');
      records = graphRecords(data);
      if (serial !== loadSerial) return;
      state.graph = records;
      const technicalIds = new Set(records.map(record => record.id));
      state.links = data.links.filter(link => technicalIds.has(link.source) && technicalIds.has(link.target) && typeof link.kind === 'string');
      notice = `Canonical generation ${data.generation}. Bounded to 80 records${data.truncated ? '; more exist' : ''}. Enter a search for native verified recall.`;
    } else if (state.shelf === 'environment') {
      const data = await api('/api/context', {auth: true, body: {query: serverQuery || 'Host hardware software infrastructure capabilities limits', thread_id: 'workspace', scope: 'technical'}});
      assert(data.schema_version === 'shared-context-v1' && data.state === 'ready' && data.trust === 'untrusted_reference' &&
        typeof data.context === 'string' && data.context.trim() && utf8.encode(data.context).length <= 4096 &&
        Array.isArray(data.request_tools) && data.request_tools.length === 0, 'Invalid Environment context.');
      records = [{id: 'environment-index', title: 'My setup / shared Environment', type: 'Host and capability map',
        summary: 'Existing bounded index/context foundation. Not a complete software inventory or a live readiness certificate.',
        kind: 'environment', status: 'candidate', content: data.context, sources: ['/api/context', '/api/index']}];
      notice = 'Existing timestamped map and current granted-root context. Refresh is manual; missing inventory is not fabricated.';
    } else if (state.shelf === 'sources') {
      const graph = await api('/api/graph?limit=80');
      const technicalIds = new Set(graphRecords(graph).map(record => record.id));
      const refs = [];
      if (token()) {
        const data = await readWorking('research');
        for (const record of workingRecords(data, 'technical')) for (const source of record.sources) refs.push({source, owner: record.id, title: record.title});
      }
      for (const link of graph.links) if (technicalIds.has(link.source) && technicalIds.has(link.target) && /source|cites|evidence|derived/i.test(link.kind)) refs.push({source: link.target, owner: link.source, title: link.kind});
      records = refs.map((ref, index) => ({id: `source-${index}`, title: ref.source, type: 'Declared evidence reference',
        summary: ref.title, kind: 'source', status: 'candidate', content: `Reference: ${ref.source}\nDeclared by: ${ref.owner}\n\nThis is a reference, not a raw-source export or verification verdict.`, sources: []}));
      notice = token() ? 'References from bounded technical Research and declared canonical source links; raw capture APIs are not exposed here.' : 'Canonical source links only. Connect protected shelves to include Research provenance.';
    } else {
      const scope = state.shelf === 'personal' ? 'personal' : 'technical';
      const shelf = state.shelf === 'discussion' ? 'discussion' : 'research';
      const query = state.shelf === 'evaluations' ? (serverQuery || 'model-evaluation') : serverQuery;
      const data = await readWorking(shelf, scope, query);
      records = workingRecords(data, scope);
      if (state.shelf === 'evaluations') records = records.filter(record => record.evaluation);
      notice = `Up to 20 ${scope} ${shelf} records${data.more ? '; more exist, narrow the search' : ''}. Server search runs on Enter. Always untrusted; no SRE promotion.`;
    }
    if (serial !== loadSerial) return;
    state.records = records;
    state.notice = notice;
    state.loading = false;
    state.selected = visibleRecords()[0]?.id || null;
    $('connection-label').textContent = state.shelf === 'sre' ? 'Canonical knowledge connected' : 'Local shelf connected';
    $('footer-state').textContent = state.shelf === 'personal' ? 'Personal working shelf / isolated' : 'Local kernel / source-bound knowledge';
    render();
    fitMap();
    if (selectedRecord()?.kind === 'canonical') await selectRecord(state.selected);
  } catch (error) {
    if (serial !== loadSerial) return;
    state.loading = false;
    state.error = error.message;
    state.records = [];
    state.selected = null;
    $('connection-label').textContent = 'Connection or authorization required';
    $('footer-state').textContent = 'Selected shelf unavailable / no records presented';
    render();
  }
}
async function selectRecord(id) {
  const serial = ++selectionSerial;
  state.selected = id;
  state.tab = 'record';
  renderExplorer();
  renderReader();
  const record = selectedRecord();
  if (record?.kind === 'canonical' && record.content === null) {
    try {
      const doc = await api('/api/node?id=' + encodeURIComponent(id));
      assert(doc.id === id && doc.stable_id === record.stableId && typeof doc.title === 'string' &&
        typeof doc.content === 'string' && typeof doc.sector === 'string' &&
        doc.sector.toLowerCase() !== 'personal' && statuses.has(doc.status), 'Invalid or personal canonical record.');
      if (serial !== selectionSerial || state.selected !== id) return;
      record.content = doc.content;
      record.status = doc.status;
      record.title = doc.title;
      record.stableId = doc.stable_id;
      record.readError = '';
      renderExplorer();
      renderReader();
    } catch (error) {
      if (serial !== selectionSerial || state.selected !== id) return;
      record.readError = error.message;
      record.content = null;
      renderExplorer();
      renderReader();
    }
  }
}
function render() {
  renderShelves();
  $('shelf-title').textContent = currentShelf().title;
  $('shelf-description').textContent = currentShelf().description;
  $('add-note').hidden = !['research', 'discussion', 'personal'].includes(state.shelf);
  $('ask-search').disabled = state.shelf === 'personal';
  $('load-notice').textContent = state.error || state.notice || 'Real records only. No sample-data fallback.';
  renderExplorer();
  renderReader();
}
function renderExplorer() {
  const visible = visibleRecords();
  if (!visible.some(record => record.id === state.selected)) state.selected = visible[0]?.id || null;
  state.page = Math.min(state.page, Math.max(0, Math.ceil(visible.length / 8) - 1));
  $('result-count').textContent = state.loading ? 'Loading...' : state.error ? 'Unavailable / no records presented' : `${visible.length} ${visible.length === 1 ? 'record' : 'records'} in this bounded view`;
  $('map-view').setAttribute('aria-pressed', String(state.view === 'map'));
  $('list-view').setAttribute('aria-pressed', String(state.view === 'list'));
  $('map-region').hidden = !visible.length || state.view !== 'map';
  $('list-region').hidden = !visible.length || state.view !== 'list';
  $('empty-state').hidden = visible.length > 0;
  $('empty-title').textContent = state.loading ? 'Loading the selected shelf' : state.error ? 'This shelf is unavailable' : 'No matching records';
  $('empty-description').textContent = state.error || (state.loading ? 'Retrieving the existing local service.' : state.shelf === 'personal' ? 'No personal working notes match. Personal content is not attached to technical assistant prompts.' : 'Try another term or clear the status filter. No fixture records are substituted.');
  $('clear-search').hidden = state.loading || !!state.error;
  $('map-page').textContent = `${state.page + 1}/${Math.max(1, Math.ceil(visible.length / 8))}`;
  $('map-prev').disabled = state.page === 0;
  $('map-next').disabled = (state.page + 1) * 8 >= visible.length;
  renderMap(visible.slice(state.page * 8, (state.page + 1) * 8));
  $('list-region').replaceChildren(...visible.map(record => {
    const button = element('button', 'record-row' + (record.id === state.selected ? ' selected' : ''));
    button.type = 'button';
    button.dataset.record = record.id;
    button.setAttribute('aria-pressed', String(record.id === state.selected));
    const text = element('span');
    text.append(element('strong', '', record.title), element('small', '', record.summary));
    button.append(text, element('span', `badge ${record.readError ? 'stale' : record.status}`, statusLabel(record)));
    button.addEventListener('click', () => selectRecord(record.id));
    return button;
  }));
}
function titleLines(title) {
  const lines = [''];
  for (const word of title.split(/\s+/)) {
    const next = `${lines.at(-1)}${lines.at(-1) ? ' ' : ''}${word}`;
    if (next.length > 24 && lines.at(-1)) lines.push(word);
    else lines[lines.length - 1] = next;
  }
  return lines;
}
function renderMap(records) {
  const map = $('mind-map');
  map.replaceChildren();
  state.mapHeight = Math.max(720, Math.ceil(records.length / 2) * 175 + 140);
  map.setAttribute('viewBox', `0 0 1080 ${state.mapHeight}`);
  map.style.height = `${state.mapHeight}px`;
  const positions = new Map(records.map((record, index) => [record.id, {x: index % 2 ? 795 : 35, y: 65 + Math.floor(index / 2) * 175}]));
  for (const record of records) {
    const p = positions.get(record.id);
    map.append(svg('path', {class: 'map-edge', d: `M540 304 C540 ${p.y + 58},${p.x + 120} 304,${p.x + 120} ${p.y + 58}`}));
  }
  const recordIds = new Set(records.map(record => record.id));
  for (const link of state.shelf === 'sre' ? state.links : []) {
    if (!recordIds.has(link.source) || !recordIds.has(link.target)) continue;
    const a = positions.get(link.source), b = positions.get(link.target);
    const path = svg('path', {class: 'evidence-edge', d: `M${a.x + 120} ${a.y + 116} C${a.x + 120} ${a.y + 145},${b.x + 120} ${b.y - 25},${b.x + 120} ${b.y}`});
    path.append(svg('title', {}, link.kind));
    map.append(path);
  }
  const root = svg('g', {transform: 'translate(420,252)'});
  root.append(svg('rect', {class: 'root-box', width: 240, height: 104}), svg('text', {class: 'root-title', x: 120, y: 41}, currentShelf().title), svg('text', {class: 'root-subtitle', x: 120, y: 67}, `${records.length} loaded records / page ${state.page + 1}`));
  map.append(root);
  for (const record of records) {
    const p = positions.get(record.id);
    const group = svg('g', {class: `record-node${record.id === state.selected ? ' selected' : ''}`, transform: `translate(${p.x},${p.y})`, 'data-record': record.id, tabindex: 0, role: 'button', 'aria-label': `${record.title}, ${statusLabel(record)}`, 'aria-pressed': String(record.id === state.selected)});
    group.append(svg('rect', {class: 'node-box', width: 240, height: 116}), svg('text', {class: 'node-kicker', x: 17, y: 23}, record.type.slice(0, 26).toUpperCase()));
    titleLines(record.title).slice(0, 2).forEach((line, index) => group.append(svg('text', {class: 'node-title', x: 17, y: 49 + index * 22}, line.slice(0, 26))));
    group.append(svg('text', {class: `node-status ${record.readError ? 'stale' : record.status}`, x: 17, y: 98}, statusLabel(record)), svg('text', {class: 'node-id', x: 220, y: 98, 'text-anchor': 'end'}, record.id.slice(0, 8)));
    group.addEventListener('click', () => selectRecord(record.id));
    group.addEventListener('keydown', event => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); selectRecord(record.id); } });
    map.append(group);
  }
  transformMap();
}
function transformMap() {
  $('mind-map').style.transform = `translate(${state.x}px,${state.y}px) scale(${state.scale})`;
  $('zoom-level').textContent = `${Math.round(state.scale * 100)}%`;
}
function fitMap() {
  if ($('map-region').hidden) return;
  const box = $('map-viewport').getBoundingClientRect();
  if (!box.width || !box.height) return;
  state.scale = Math.min(box.width / 1080, (box.height - 65) / state.mapHeight, 1.3);
  state.x = (box.width - 1080 * state.scale) / 2;
  state.y = (box.height - 65 - state.mapHeight * state.scale) / 2;
  transformMap();
}
function zoom(factor) {
  const box = $('map-viewport').getBoundingClientRect(), old = state.scale;
  state.scale = Math.min(2, Math.max(.2, old * factor));
  state.x = box.width / 2 - (box.width / 2 - state.x) * state.scale / old;
  state.y = box.height / 2 - (box.height / 2 - state.y) * state.scale / old;
  transformMap();
}
function section(title, text) {
  $('record-content').append(element('h3', '', title), element('p', 'record-body', text));
}
function renderReader() {
  const record = selectedRecord();
  $('record-heading').replaceChildren();
  $('record-content').replaceChildren();
  $('record-actions').replaceChildren();
  for (const tab of ['record', 'evidence', 'history']) {
    $('tab-' + tab).setAttribute('aria-selected', String(state.tab === tab));
    $('tab-' + tab).tabIndex = state.tab === tab ? 0 : -1;
  }
  $('record-content').setAttribute('aria-labelledby', 'tab-' + state.tab);
  if (!record) {
    $('record-heading').append(element('p', 'record-type', 'No selection'), element('h2', '', 'A record, not a guess.'));
    section('Choose a record', state.error || 'Select a record to read its actual content, provenance and available actions.');
    return;
  }
  $('record-origin').textContent = record.kind === 'canonical' ? 'CANONICAL' : 'WORKING REFERENCE';
  const badges = element('div', 'record-badges');
  badges.append(element('span', `badge ${record.readError ? 'stale' : record.status}`, statusLabel(record)));
  if (record.kind === 'working') badges.append(element('span', 'badge', record.scope === 'personal' ? 'Personal / isolated' : 'Not SRE RAG'));
  $('record-heading').append(element('p', 'record-type', record.type), element('h2', '', record.title), badges);
  if (state.tab === 'record') {
    section(record.readError ? 'Read failed / content withheld' : 'Content', record.readError || (record.content === null ? 'Reading the current canonical document...' : record.content));
    $('record-content').append(element('p', 'record-id', `ID: ${record.id}${record.stableId ? `\nStable ID: ${record.stableId}` : ''}`));
  } else if (state.tab === 'evidence') {
    section('Trust and provenance', record.kind === 'canonical' ? 'Status is read from the canonical service. This adapter does not expose a full raw-source export; no missing source hash is invented.' : 'Working shelf records remain untrusted. Their declared references are not verification verdicts.');
    if (record.sourceHash) section('Immutable working-source hash', record.sourceHash);
    for (const reference of record.sources) {
      const card = element('p', 'evidence-warning', reference);
      try {
        const url = new URL(reference);
        if (url.protocol === 'https:' && !url.username && !url.password) {
          const link = element('a', '', 'Open source');
          link.href = url.href; link.target = '_blank'; link.rel = 'noopener noreferrer';
          card.append(document.createElement('br'), link);
        }
      } catch { /* Opaque references and local paths remain text, not executable links. */ }
      $('record-content').append(card);
    }
    for (const link of record.kind === 'canonical' ? state.links.filter(link => link.source === record.id || link.target === record.id) : []) {
      const other = link.source === record.id ? link.target : link.source;
      const target = state.records.find(item => item.id === other);
      const button = element('button', 'source-link', `${link.kind}: ${target?.title || other}`);
      button.type = 'button';
      button.disabled = !target;
      button.addEventListener('click', () => selectRecord(other));
      $('record-content').append(button);
    }
    if (!record.sources.length && record.kind !== 'canonical') section('References', 'No source references were supplied for this record.');
  } else {
    section('Persisted record', record.created ? `Created: ${record.created}` : 'The read API does not supply a full record-history timeline.');
    for (const entry of activity.get(record.id) || []) section(entry.action, entry.reason);
    section('History limits', 'The current status is canonical; working records are immutable. This panel does not manufacture prior judgments. Correlated core events are available under System.');
  }
  if (record.scope !== 'personal') {
    const ask = element('button', '', 'Ask about this record');
    ask.type = 'button';
    ask.addEventListener('click', () => { openAssistant(); $('assistant-input').value = `Explain the technical record "${record.title}" (ID ${record.id}) and its stated limits.`; $('assistant-input').focus(); });
    $('record-actions').append(ask);
  }
  if (record.scope !== 'personal' && (record.kind === 'canonical' && record.content !== null && !record.readError || record.evaluation)) {
    const review = element('button', 'primary', 'Review answer / record');
    review.type = 'button'; review.id = 'review-record';
    review.addEventListener('click', () => openReview(record));
    $('record-actions').append(review);
  }
  $('record-actions').append(element('p', 'action-note', record.scope === 'personal' ? 'Personal content is not attached to technical chat or recall.' : 'Answer assessment stays in Research. Canonical admission requires its own explicit judgment.'));
}
function openAssistant() { $('assistant-panel').hidden = false; $('assistant-toggle').setAttribute('aria-expanded', 'true'); }
function closeAssistant() { $('assistant-panel').hidden = true; $('assistant-toggle').setAttribute('aria-expanded', 'false'); }
function message(text, user = false) {
  const node = element('p', 'assistant-message' + (user ? ' user' : ''), text);
  $('assistant-messages').append(node);
  $('assistant-messages').scrollTop = $('assistant-messages').scrollHeight;
  return node;
}
async function sendMessage(text, readOnly = false) {
  assert(text.trim(), 'Enter a message.');
  assert(!chatBusy, 'A reply is already in progress; wait for the current request.');
  const mode = readOnly ? 'research' : $('assistant-mode').value;
  if (mode === 'fix' || /^(?:\/(?:verify|reject|yolo|edit|idea|remember|hylla|index|observe|mouth)\b|index$)/i.test(text.trim())) requireToken();
  openAssistant();
  message(text, true);
  const waiting = message('Waiting for the local kernel...');
  chatBusy = true;
  $('assistant-send').disabled = true;
  $('review-reply').hidden = true;
  lastReply = null;
  try {
    const headers = {'Content-Type': 'application/json', Accept: 'text/event-stream'};
    if (token()) headers.Authorization = 'Bearer ' + token();
    const response = await fetch('/api/chat', {method: 'POST', headers, body: JSON.stringify({message: text, stream: true, tool_mode: mode})});
    let answer = '';
    if (!(response.headers.get('content-type') || '').includes('text/event-stream')) {
      const data = await response.json();
      assert(response.ok && !data.error && typeof data.response === 'string', data.error || data.response || `Chat HTTP ${response.status}`);
      answer = data.response;
    } else {
      assert(response.ok && response.body, `Chat HTTP ${response.status}`);
      const reader = response.body.getReader(), decoder = new TextDecoder();
      let buffer = '', assembled = '', done = false;
      const consume = () => {
        buffer = buffer.replace(/\r\n/g, '\n');
        for (;;) {
          const split = buffer.indexOf('\n\n');
          if (split < 0) break;
          const block = buffer.slice(0, split); buffer = buffer.slice(split + 2);
          const lines = block.split('\n').filter(line => line.startsWith('data:')).map(line => line.slice(5).trimStart());
          if (!lines.length) continue;
          const event = JSON.parse(lines.join('\n'));
          if (event.type === 'token' && typeof event.text === 'string') { assembled += event.text; waiting.textContent = assembled; }
          else if (event.type === 'status' && !assembled && event.text) waiting.textContent = event.text;
          else if (event.type === 'ping' && !assembled) waiting.textContent = 'Local model is still prefilling; do not submit a second request.';
          else if (event.type === 'error' || event.error) throw new Error(event.error || event.text || 'Kernel reply failed.');
          else if (event.type === 'done') { done = true; answer = typeof event.response === 'string' ? event.response : assembled; }
        }
      };
      for (;;) {
        const chunk = await reader.read();
        buffer += decoder.decode(chunk.value || new Uint8Array(), {stream: !chunk.done});
        consume();
        if (chunk.done) break;
      }
      assert(done && answer.trim(), 'Reply stream ended without a completed answer; partial text is not a successful result.');
    }
    assert(answer.trim() && !/^Error:/i.test(answer), answer || 'Kernel returned an empty answer.');
    waiting.textContent = answer;
    if (!text.trim().startsWith('/') && !readOnly) {
      lastReply = {id: 'response-' + crypto.randomUUID(), title: text, kind: 'response', content: answer, sources: [], status: 'candidate'};
      $('review-reply').hidden = false;
    }
    $('assistant-input').value = '';
    return answer;
  } catch (error) {
    waiting.textContent = `Request failed: ${error.message}`;
    throw error;
  } finally { chatBusy = false; $('assistant-send').disabled = false; }
}
function openReview(record) {
  assert(record.scope !== 'personal', 'Personal records cannot be assessed into technical Research.');
  reviewRecord = record;
  reviewOriginalContent = record.content;
  $('review-title').textContent = 'Correct answer and SRE admission are different decisions.';
  $('review-explanation').textContent = record.kind === 'canonical' ? 'Keep an answer assessment in Research, or explicitly judge this canonical record. A correct answer need not become troubleshooting advice.' : 'Append an answer assessment in Model Evaluations. This does not change the source record or admit its subject to RAG.';
  for (const option of $('review-destination').options) option.disabled = option.value !== 'evaluation' && record.kind !== 'canonical';
  $('review-destination').value = 'evaluation';
  $('review-model').value = '';
  $('review-reason').value = '';
  $('review-error').textContent = '';
  $('review-dialog').showModal();
}
async function sha256(text) {
  return Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', utf8.encode(text))), byte => byte.toString(16).padStart(2, '0')).join('');
}
async function storeWorking(payload) {
  assert(utf8.encode(payload.text).length <= 32768 && utf8.encode(payload.title).length <= 512, 'Note exceeds the working-shelf byte limit; no write sent.');
  const signature = JSON.stringify(payload);
  if (!pendingPost || pendingPost.signature !== signature) pendingPost = {signature, id: crypto.randomUUID()};
  const request = {...payload, action: 'post', request_id: pendingPost.id, thread_id: 'workspace', speaker: 'operator'};
  const receipt = await api('/api/shelf', {auth: true, body: request});
  assert(receipt.schema_version === 'working-shelf-v1' && receipt.status === 'stored' &&
    receipt.trust === 'untrusted' && receipt.promoted === false && receipt.record?.text === payload.text &&
    receipt.record?.scope === payload.scope && receipt.record?.request_id === request.request_id, 'Working record was not confirmed; retry preserves this request identity.');
  const read = await readWorking(payload.shelf, payload.scope, payload.title);
  const records = workingRecords(read, payload.scope);
  const committed = records.find(record => record.id === receipt.record._id);
  assert(committed?.content === payload.text, 'Stored receipt received, but exact shelf readback failed; do not claim searchable success.');
  pendingPost = null;
  return receipt;
}
async function saveReview() {
  const record = reviewRecord, reason = $('review-reason').value.trim(), decision = $('review-destination').value;
  assert(record && record.scope !== 'personal' && reason.length >= 8, 'Give a meaningful technical review reason.');
  requireToken();
  $('review-confirm').disabled = true;
  $('review-error').textContent = '';
  try {
    if (decision === 'evaluation') {
      assert(typeof record.content === 'string' && !record.readError, 'Reload the record before assessing an unavailable source.');
      const hash = await sha256(record.content);
      const model = $('review-model').value.trim();
      const body = `Assessment: operator_reviewed_correct\nSource record: ${record.id}\nComplete content SHA-256: ${hash}\nModel attribution: ${model ? 'operator-supplied: ' + model : 'not independently supplied by this read API'}\n\nOperator reason:\n${reason}` +
        (record.kind === 'response' ? `\n\nOriginal request:\n${record.title}\n\nOriginal response:\n${record.content}` : '');
      await storeWorking({shelf: 'research', scope: 'technical', title: `model-evaluation ${record.id}`, text: body, sources: [`workspace-record:${record.id}`, `content-sha256:${hash}`]});
      activity.set(record.id, [...(activity.get(record.id) || []), {action: 'Answer assessment saved / Research only', reason}]);
      notify('Answer assessment stored and read back in Research. Canonical status was not changed.');
    } else {
      assert(record.kind === 'canonical' && ['verified', 'rejected'].includes(decision), 'Canonical judgment is unavailable for this record.');
      record.readError = 'Judgment attempted; current canonical status must be rechecked.';
      record.content = null;
      renderExplorer();
      renderReader();
      await api('/api/judge', {auth: true, body: {id: record.stableId || record.id, status: decision, reasoning: reason}});
      const doc = await api('/api/node?id=' + encodeURIComponent(record.id));
      assert(doc.id === record.id && doc.stable_id === record.stableId && doc.sector !== 'personal' &&
        doc.status === decision && doc.content === reviewOriginalContent, 'Judgment submitted, but exact canonical status/content readback was not confirmed.');
      record.status = doc.status;
      record.content = doc.content;
      record.readError = '';
      activity.set(record.id, [...(activity.get(record.id) || []), {action: `Canonical status confirmed: ${decision}`, reason}]);
      notify('Canonical judgment confirmed. Original content was not rewritten.');
    }
    $('review-dialog').close();
    render();
  } finally { $('review-confirm').disabled = false; }
}
async function showDoor(name) {
  assert(['heal', 'vram', 'pending', 'last-edit', 'sre', 'chain', 'events', 'doors', 'desk'].includes(name), 'Unsupported System door.');
  $('system-output').textContent = 'Reading ' + name + '...';
  try {
    const data = await api('/api/' + name);
    $('system-output').textContent = typeof data.response === 'string' ? data.response : JSON.stringify(data, null, 2);
  } catch (error) { $('system-output').textContent = 'Read failed: ' + error.message; }
}

$('search').addEventListener('input', event => { state.query = event.target.value; state.page = 0; renderExplorer(); renderReader(); fitMap(); if (selectedRecord()?.content === null) selectRecord(state.selected); });
$('search-form').addEventListener('submit', async event => {
  event.preventDefault();
  try {
    if (state.shelf === 'sre') await sendMessage('/recall ' + $('search').value.trim(), true);
    else if (state.shelf !== 'sources') { state.query = ''; await loadShelf($('search').value.trim()); }
  } catch (error) { notify(error.message); }
});
$('ask-search').addEventListener('click', () => { openAssistant(); $('assistant-input').value = $('search').value; $('assistant-input').focus(); });
$('refresh-shelf').addEventListener('click', () => loadShelf());
$('status-filter').addEventListener('change', event => { state.filter = event.target.value; state.page = 0; renderExplorer(); renderReader(); fitMap(); if (selectedRecord()?.content === null) selectRecord(state.selected); });
$('clear-search').addEventListener('click', () => { state.query = ''; state.filter = 'all'; $('search').value = ''; $('status-filter').value = 'all'; render(); fitMap(); if (selectedRecord()?.content === null) selectRecord(state.selected); });
for (const view of ['map', 'list']) $(view + '-view').addEventListener('click', () => { state.view = view; renderExplorer(); fitMap(); });
for (const tab of ['record', 'evidence', 'history']) $('tab-' + tab).addEventListener('click', () => { state.tab = tab; renderReader(); });
const tabs = [...document.querySelectorAll('.reader-tabs [role="tab"]')];
tabs.forEach((button, index) => button.addEventListener('keydown', event => {
  if (!['ArrowLeft', 'ArrowRight'].includes(event.key)) return;
  event.preventDefault();
  const next = tabs[(index + (event.key === 'ArrowRight' ? 1 : -1) + tabs.length) % tabs.length];
  next.click(); next.focus();
}));
$('zoom-in').addEventListener('click', () => zoom(1.2));
$('zoom-out').addEventListener('click', () => zoom(1 / 1.2));
$('fit-map').addEventListener('click', fitMap);
for (const [id, delta] of [['map-prev', -1], ['map-next', 1]]) $(id).addEventListener('click', () => { state.page += delta; renderExplorer(); fitMap(); });
$('map-viewport').addEventListener('pointerdown', event => {
  if (event.button !== 0 || event.target.closest('[data-record]')) return;
  drag = {x: event.clientX, y: event.clientY, originX: state.x, originY: state.y};
  $('map-viewport').setPointerCapture(event.pointerId); $('map-viewport').classList.add('panning');
});
$('map-viewport').addEventListener('pointermove', event => { if (drag) { state.x = drag.originX + event.clientX - drag.x; state.y = drag.originY + event.clientY - drag.y; transformMap(); } });
for (const type of ['pointerup', 'pointercancel', 'lostpointercapture']) $('map-viewport').addEventListener(type, () => { drag = null; $('map-viewport').classList.remove('panning'); });
$('map-viewport').addEventListener('keydown', event => {
  if (event.target !== $('map-viewport')) return;
  const shift = {ArrowLeft: [35, 0], ArrowRight: [-35, 0], ArrowUp: [0, 35], ArrowDown: [0, -35]}[event.key];
  if (shift) { event.preventDefault(); state.x += shift[0]; state.y += shift[1]; transformMap(); }
});
$('assistant-toggle').addEventListener('click', () => $('assistant-panel').hidden ? openAssistant() : closeAssistant());
$('assistant-close').addEventListener('click', closeAssistant);
$('assistant-form').addEventListener('submit', event => { event.preventDefault(); sendMessage($('assistant-input').value).catch(error => notify(error.message)); });
$('review-reply').addEventListener('click', () => { if (lastReply) openReview(lastReply); });
$('connect').addEventListener('click', () => { $('auth-token').value = ''; $('auth-error').textContent = ''; $('auth-dialog').showModal(); });
$('auth-cancel').addEventListener('click', () => $('auth-dialog').close());
$('auth-forget').addEventListener('click', () => { sessionStorage.removeItem('godbrain_write_token'); $('auth-dialog').close(); loadShelf(); });
$('auth-form').addEventListener('submit', async event => {
  event.preventDefault();
  const value = $('auth-token').value.trim();
  if (!value) { $('auth-error').textContent = 'A blank token cannot authorize a request.'; return; }
  sessionStorage.setItem('godbrain_write_token', value);
  $('auth-token').value = ''; $('auth-dialog').close();
  await loadShelf();
});
$('review-cancel').addEventListener('click', () => $('review-dialog').close());
$('review-form').addEventListener('submit', event => { event.preventDefault(); saveReview().catch(error => { $('review-error').textContent = error.message; }); });
$('add-note').addEventListener('click', () => {
  try { requireToken(); } catch (error) { notify(error.message); return; }
  $('note-heading').textContent = state.shelf === 'personal' ? 'Add a personal working note' : 'Add a working note';
  $('note-title').value = ''; $('note-text').value = ''; $('note-error').textContent = '';
  $('note-dialog').showModal();
});
$('note-cancel').addEventListener('click', () => $('note-dialog').close());
$('note-form').addEventListener('submit', async event => {
  event.preventDefault();
  $('note-save').disabled = true;
  try {
    await storeWorking({shelf: state.shelf === 'discussion' ? 'discussion' : 'research', scope: state.shelf === 'personal' ? 'personal' : 'technical',
      title: $('note-title').value.trim(), text: $('note-text').value.trim(), sources: []});
    $('note-dialog').close(); notify('Working note stored and read back. Not promoted to RAG.'); await loadShelf();
  } catch (error) { $('note-error').textContent = error.message; }
  finally { $('note-save').disabled = false; }
});
$('system').addEventListener('click', async () => {
  $('system-dialog').showModal(); $('system-summary').textContent = 'Reading passive snapshots...';
  const results = await Promise.allSettled([api('/api/heal'), api('/api/vram')]);
  $('system-summary').replaceChildren(...results.map((result, index) => element('p', 'record-body',
    `${index ? 'GPU / model snapshot' : 'Host recovery snapshot'}: ${result.status === 'fulfilled' ? (result.value.response || JSON.stringify(result.value)) : 'unavailable: ' + result.reason.message}`)));
});
$('system-close').addEventListener('click', () => $('system-dialog').close());
document.querySelectorAll('[data-door]').forEach(button => button.addEventListener('click', () => showDoor(button.dataset.door)));
$('desk-btn').addEventListener('click', () => showDoor('desk'));
$('environment-refresh').addEventListener('click', async () => {
  try {
    requireToken();
    const result = await api('/api/index', {auth: true, body: {}});
    assert(result.state === 'indexed' && result.persisted === true && result.promoted === false, 'Environment refresh was not confirmed.');
    $('system-output').textContent = 'Bounded Environment index refreshed and persisted. No permissions expanded and no RAG promotion.';
    if (state.shelf === 'environment') await loadShelf();
  } catch (error) { $('system-output').textContent = 'Environment refresh failed: ' + error.message; }
});
function setWallpaper(name) {
  document.body.dataset.wallpaper = name;
  $('wallpaper').textContent = 'Wallpaper: ' + (name === 'tidal' ? 'Tidal' : 'Courtyard');
  sessionStorage.setItem('godbrain-workspace-wallpaper', name);
}
$('wallpaper').addEventListener('click', () => setWallpaper(document.body.dataset.wallpaper === 'tidal' ? 'courtyard' : 'tidal'));
document.addEventListener('keydown', event => {
  const typing = event.target.matches('input,textarea,select,[contenteditable="true"]');
  if (event.key === '/' && !typing && !document.querySelector('dialog[open]')) { event.preventDefault(); $('search').focus(); }
  if (event.key === 'Escape' && !document.querySelector('dialog[open]')) closeAssistant();
});
window.addEventListener('resize', fitMap);
const savedWallpaper = sessionStorage.getItem('godbrain-workspace-wallpaper');
setWallpaper(['tidal', 'courtyard'].includes(savedWallpaper) ? savedWallpaper : crypto.getRandomValues(new Uint8Array(1))[0] % 2 ? 'tidal' : 'courtyard');
$('status-filter').value = state.filter;
loadShelf();
