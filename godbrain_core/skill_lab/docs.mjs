import { createHash } from 'node:crypto';
import { promises as fs } from 'node:fs';
import path from 'node:path';
import { clip, readJson, writeJson } from './gym-core.mjs';

const ALLOWED_HOSTS = new Set([
  'react.dev',
  'developer.mozilla.org',
  'nodejs.org',
  'www.typescriptlang.org',
]);
const LIMIT = 1024 * 1024;

export function documentationUrl(value) {
  const url = new URL(value);
  if (url.protocol !== 'https:' || !ALLOWED_HOSTS.has(url.hostname) ||
      url.username || url.password || url.port || url.search) {
    throw new Error('Documentation must come from an allowlisted official HTTPS source.');
  }
  url.hash = '';
  return url.href;
}

export function articleText(html) {
  const main = html.match(/<main\b[^>]*>([\s\S]*?)<\/main>/i)?.[1] ??
    html.match(/<article\b[^>]*>([\s\S]*?)<\/article>/i)?.[1] ?? html;
  return main.replace(/<(script|style|nav)\b[^>]*>[\s\S]*?<\/\1>/gi, ' ')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"')
    .replace(/&#x27;|&#39;|&apos;/g, "'").replace(/&amp;/g, '&').replace(/&nbsp;/g, ' ')
    .replace(/\s+/g, ' ').trim();
}

export function createDocumentationReader(workDir, { offline = false } = {}) {
  return async (task, signal) => {
    const directory = path.join(workDir, 'docs');
    await fs.mkdir(directory, { recursive: true });
    const excerpts = [];
    const warnings = [];
    for (const reference of (task.docs ?? []).slice(0, 2)) {
      const url = documentationUrl(typeof reference === 'string' ? reference : reference.url);
      const key = createHash('sha256').update(url).digest('hex');
      const cached = await readJson(path.join(directory, `${key}.json`), null);
      if (cached) {
        if (cached.url !== url || typeof cached.text !== 'string' ||
            createHash('sha256').update(cached.text).digest('hex') !== cached.sha256) {
          throw new Error('Cached documentation content does not match its receipt.');
        }
        excerpts.push(`${url} (cached ${cached.fetchedAt})\n${clip(cached.text, 1400)}`);
        continue;
      }
      if (offline) {
        warnings.push(`Offline: ${url} is not cached; proceeding from the exercise, not claiming a documentation read.`);
        continue;
      }
      let record;
      try {
        const response = await fetch(url, {
          signal: AbortSignal.any([signal, AbortSignal.timeout(15_000)]),
          redirect: 'error', headers: { Accept: 'text/html' },
        });
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
        const reader = response.body.getReader();
        const buffers = [];
        let size = 0;
        try {
          for (;;) {
            const { done, value } = await reader.read();
            if (done) break;
            size += value.length;
            if (size > LIMIT) throw new Error('Documentation page exceeds 1 MiB.');
            buffers.push(Buffer.from(value));
          }
        } finally {
          await reader.cancel();
          reader.releaseLock();
        }
        const text = articleText(Buffer.concat(buffers).toString('utf8'));
        if (text.length < 100) throw new Error('No usable documentation article was found.');
        record = {
          url, fetchedAt: new Date().toISOString(), text: text.slice(0, 24_000),
          trust: 'reference-only-not-a-verified-skill',
        };
        record.sha256 = createHash('sha256').update(record.text).digest('hex');
      } catch (error) {
        if (signal.aborted) throw signal.reason;
        warnings.push(`${url}: ${error.message}; no fresh documentation evidence.`);
        continue;
      }
      await writeJson(path.join(directory, `${key}.json`), record);
      excerpts.push(`${url}\n${clip(record.text, 1400)}`);
    }
    return { text: excerpts.join('\n\n'), warnings };
  };
}
