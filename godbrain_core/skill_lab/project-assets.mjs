import { createHash } from 'node:crypto';
import { promises as fs } from 'node:fs';
import path from 'node:path';

const PROJECT_ID = /^[a-z][a-z0-9-]{0,47}$/;
const IMAGE_ID = /^[A-Z][A-Z0-9_]{0,47}$/;
const SHA256 = /^[a-f0-9]{64}$/;
const MAX_FILE = 5 * 1024 * 1024;
const MAX_TOTAL = 32 * 1024 * 1024;

function fields(value, names) {
  if (!value || typeof value !== 'object' || Array.isArray(value) ||
      Object.keys(value).length !== names.length || names.some(name => !Object.hasOwn(value, name))) {
    throw new Error('Unknown or missing project catalog field.');
  }
}

export function projectIds(value = []) {
  if (!Array.isArray(value) || value.length > 16 ||
      value.some(id => typeof id !== 'string' || !PROJECT_ID.test(id)) ||
      new Set(value).size !== value.length) throw new Error('Invalid project image selection.');
  return [...value];
}

function text(value, limit, field) {
  if (typeof value !== 'string' || !value.trim() || value.length > limit || /[\u0000-\u001f]/.test(value)) {
    throw new Error(`Invalid project catalog ${field}.`);
  }
  return value;
}

function httpsLink(value) {
  const url = new URL(text(value, 500, 'link'));
  const hostname = url.hostname.replace(/\.$/, '');
  if (url.protocol !== 'https:' || url.username || url.password || url.search || url.port ||
      !/^[a-z0-9.-]+$/i.test(hostname) || !hostname.includes('.') ||
      /^(?:\d+\.){3}\d+$/.test(hostname) || /\.(?:local|localhost|internal|lan|home|invalid|test)$/i.test(hostname)) {
    throw new Error('Project links must use public HTTPS hostnames without credentials.');
  }
  return url.href;
}

export function rasterDimensions(bytes) {
  if (bytes.length >= 24 && bytes.subarray(0, 8).equals(Buffer.from('89504e470d0a1a0a', 'hex')) &&
      bytes.toString('ascii', 12, 16) === 'IHDR') {
    return { width: bytes.readUInt32BE(16), height: bytes.readUInt32BE(20), type: 'image/png' };
  }
  if (bytes.length >= 30 && bytes.toString('ascii', 0, 4) === 'RIFF' &&
      bytes.toString('ascii', 8, 12) === 'WEBP') {
    const chunk = bytes.toString('ascii', 12, 16);
    if (chunk === 'VP8X') return { width: 1 + bytes.readUIntLE(24, 3), height: 1 + bytes.readUIntLE(27, 3), type: 'image/webp' };
    if (chunk === 'VP8L' && bytes[20] === 0x2f) {
      const bits = bytes.readUInt32LE(21);
      return { width: 1 + (bits & 0x3fff), height: 1 + ((bits >>> 14) & 0x3fff), type: 'image/webp' };
    }
    if (chunk === 'VP8 ' && bytes.subarray(23, 26).equals(Buffer.from('9d012a', 'hex'))) {
      return { width: bytes.readUInt16LE(26) & 0x3fff, height: bytes.readUInt16LE(28) & 0x3fff, type: 'image/webp' };
    }
  }
  throw new Error('Project images must be PNG or WebP rasters.');
}

async function localFile(root, relative, limit) {
  let file = root;
  for (const part of relative.split('/')) {
    file = path.join(file, part);
    if ((await fs.lstat(file)).isSymbolicLink()) throw new Error('Project assets cannot use links or junctions.');
  }
  const stat = await fs.stat(file);
  if (!stat.isFile() || stat.size > limit) throw new Error('Project asset is missing or too large.');
  const bytes = await fs.readFile(file);
  if (bytes.length > limit) throw new Error('Project asset grew beyond its limit.');
  return bytes;
}

export async function readProjectCatalogDirectory(root, selectedIds = null) {
  const selected = selectedIds == null ? null : projectIds(selectedIds);
  let raw;
  try {
    if ((await fs.lstat(root)).isSymbolicLink()) throw new Error('Project catalog cannot use a link or junction.');
    raw = await localFile(root, 'catalog.json', 256 * 1024);
  }
  catch (error) {
    if (error.code === 'ENOENT' && selected?.length === 0) return null;
    if (error.code === 'ENOENT' && selected == null) return null;
    throw error;
  }
  const catalog = JSON.parse(raw.toString('utf8'));
  fields(catalog, ['schema_version', 'projects']);
  if (catalog.schema_version !== 1 || !Array.isArray(catalog.projects) ||
      catalog.projects.length > 16) throw new Error('Invalid project catalog schema.');
  const seen = new Set(), assets = new Map(), projects = [];
  let total = 0, imageCount = 0;
  for (const project of catalog.projects) {
    fields(project, ['id', 'title', 'description', 'url', 'source_url', 'cover', 'images']);
    if (typeof project?.id !== 'string' || !PROJECT_ID.test(project.id) || seen.has(project.id) ||
        !Array.isArray(project.images) || !project.images.length || project.images.length > 16) {
      throw new Error('Invalid or duplicate catalog project.');
    }
    seen.add(project.id);
    const images = [], ids = new Set();
    for (const image of project.images) {
      fields(image, ['id', 'path', 'sha256', 'width', 'height', 'description', 'capture_kind']);
      if (++imageCount > 128 || !IMAGE_ID.test(image.id) || ids.has(image.id) ||
          !SHA256.test(image.sha256) ||
          (image.path !== `assets/${project.id}/${image.id}.webp` &&
          image.path !== `assets/${project.id}/${image.id}.png`)) throw new Error('Invalid catalog image identity/path/hash.');
      ids.add(image.id);
      const bytes = await localFile(root, image.path, MAX_FILE);
      total += bytes.length;
      if (total > MAX_TOTAL || createHash('sha256').update(bytes).digest('hex') !== image.sha256) {
        throw new Error('Project image hash mismatch or catalog size limit exceeded.');
      }
      const size = rasterDimensions(bytes);
      if (size.width !== image.width || size.height !== image.height || size.width < 1 ||
          size.height < 1 || size.width > 4096 || size.height > 8192 || size.width * size.height > 25_000_000 ||
          (size.type === 'image/png') !== image.path.endsWith('.png')) throw new Error('Project image dimensions/type mismatch.');
      const url = `./project-assets/${image.path.slice('assets/'.length)}?v=${image.sha256}`;
      const item = {
        id: image.id, url, path: image.path, sha256: image.sha256,
        width: image.width, height: image.height,
        description: text(image.description, 400, 'image description'),
        captureKind: text(image.capture_kind, 80, 'capture kind'),
      };
      images.push(item);
      if (selected == null || selected.includes(project.id)) {
        assets.set(url.slice(1), { bytes, type: size.type });
      }
    }
    if (!ids.has(project.cover)) throw new Error('Project cover does not identify a project image.');
    const item = {
      id: project.id, title: text(project.title, 120, 'title'),
      description: text(project.description, 600, 'description'),
      url: httpsLink(project.url), sourceUrl: httpsLink(project.source_url),
      cover: project.cover, images,
    };
    if (selected == null || selected.includes(project.id)) projects.push(item);
  }
  if (selected?.some(id => !seen.has(id))) throw new Error('A selected project is missing from the catalog.');
  return { projects, assets, catalogHash: createHash('sha256').update(raw).digest('hex') };
}

export const loadProjectCatalog = (workDir, selectedIds = null) =>
  readProjectCatalogDirectory(path.join(workDir, 'showcase'), selectedIds);

export function projectAssetRequest(catalog, relativeUrl) {
  if (!catalog || /[\r\n\\#]/.test(relativeUrl)) return null;
  return catalog.assets.get(relativeUrl) ?? null;
}
