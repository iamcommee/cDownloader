// Decision logic for the cDownloader browser add-on. Pure functions so they can be tested with Node.

/** `*` matches any run of characters; everything else matches itself; case-insensitive. */
export function wildcardMatch(pattern, text) {
  if (typeof pattern !== 'string' || typeof text !== 'string' || pattern === '') return false;
  const p = pattern.toLowerCase();
  const t = text.toLowerCase();
  let pi = 0;
  let ti = 0;
  let star = -1;
  let mark = 0;
  while (ti < t.length) {
    if (pi < p.length && p[pi] !== '*' && p[pi] === t[ti]) {
      pi += 1;
      ti += 1;
    } else if (pi < p.length && p[pi] === '*') {
      star = pi;
      mark = ti;
      pi += 1;
    } else if (star >= 0) {
      pi = star + 1;
      mark += 1;
      ti = mark;
    } else {
      return false;
    }
  }
  while (pi < p.length && p[pi] === '*') pi += 1;
  return pi === p.length;
}

export function matchesAny(patterns, text) {
  return Array.isArray(patterns) && patterns.some((pattern) => wildcardMatch(String(pattern).trim(), text));
}

/** Lower-case extension of a file name or of a URL's path, without the dot. */
export function extensionOf(nameOrUrl) {
  if (typeof nameOrUrl !== 'string' || nameOrUrl === '') return '';
  let path = nameOrUrl;
  try {
    path = new URL(nameOrUrl).pathname;
  } catch {
    path = nameOrUrl.split(/[?#]/)[0];
  }
  const name = path.split(/[\\/]/).pop() || '';
  const dot = name.lastIndexOf('.');
  return dot > 0 && dot < name.length - 1 ? name.slice(dot + 1).toLowerCase() : '';
}

/** Extensions for common download MIME types, used when neither the name nor the URL has one. */
const mimeExtensions = {
  'application/zip': 'zip',
  'application/x-zip-compressed': 'zip',
  'application/pdf': 'pdf',
  'application/x-rar-compressed': 'rar',
  'application/vnd.rar': 'rar',
  'application/x-7z-compressed': '7z',
  'application/gzip': 'gz',
  'application/x-apple-diskimage': 'dmg',
  'application/x-msdownload': 'exe',
  'application/vnd.android.package-archive': 'apk',
  'application/x-iso9660-image': 'iso',
  'video/mp4': 'mp4',
  'video/webm': 'webm',
  'video/quicktime': 'mov',
  'audio/mpeg': 'mp3',
  'audio/mp4': 'm4a',
  'application/vnd.apple.mpegurl': 'm3u8',
  'application/x-mpegurl': 'm3u8',
  'audio/mpegurl': 'm3u8',
  'audio/x-mpegurl': 'm3u8',
};

const neverTakeOver = /^(blob|data|about|chrome|chrome-extension|edge|file|javascript):/i;

/**
 * Whether the add-on should take this browser download over and hand it to cDownloader.
 * download: { url, filename, mime, skipKey, forceKey }
 * settings: { integrationEnabled, extensions, dontCaptureSites, addressExceptions }
 * The skip key always lets the browser download. The force key takes over any type,
 * even from excluded sites, but never when integration is switched off.
 */
export function shouldIntercept(download, settings) {
  if (!download || !settings || !settings.integrationEnabled) return false;
  const url = String(download.url || '');
  if (!url || neverTakeOver.test(url)) return false;
  if (download.skipKey) return false;
  if (download.forceKey) return true;
  let host = '';
  try {
    host = new URL(url).hostname;
  } catch {
    return false;
  }
  if (matchesAny(settings.dontCaptureSites, host) || matchesAny(settings.dontCaptureSites, url)) return false;
  if (matchesAny(settings.addressExceptions, url)) return false;
  const mime = String(download.mime || '').split(';')[0].trim().toLowerCase();
  const ext = extensionOf(download.filename) || extensionOf(url) || mimeExtensions[mime] || '';
  return ext !== '' && matchesAny(settings.extensions, ext);
}

function headerValue(headers, name) {
  if (!headers) return undefined;
  const wanted = name.toLowerCase();
  if (Array.isArray(headers)) {
    const found = headers.find((header) => header && String(header.name).toLowerCase() === wanted);
    return found ? found.value : undefined;
  }
  for (const key of Object.keys(headers)) {
    if (key.toLowerCase() === wanted) return headers[key];
  }
  return undefined;
}

const streamPieceTypes = ['video/mp2t', 'audio/mp2t', 'video/iso.segment'];
const streamPieceExtensions = ['ts', 'm4s', 'm4f', 'cmfv', 'cmfa', 'mts'];
const hlsTypes = ['application/vnd.apple.mpegurl', 'application/x-mpegurl', 'audio/mpegurl', 'audio/x-mpegurl'];
const adOrTracking = /(doubleclick\.net|googlesyndication|googleadservices|adservice|\/ads?\/|[?&]ad_?id=|beacon|\/pixel|analytics|tracking|imasdk)/i;
const protectedHints = /(widevine|playready|fairplay|\.ism\/manifest|vnd\.ms-sstr|\bdrm\b|license)/i;
// YouTube streams picture and sound in separate pieces from googlevideo.com; the page itself is offered instead.
const youtubePieces = /^https?:\/\/([a-z0-9-]+\.)*googlevideo\.com\/videoplayback/i;

/** Facebook and Instagram fetch picture and sound in byte ranges named in the address; one range is not a video. */
function isByteRangePiece(url) {
  try {
    const params = new URL(url).searchParams;
    return params.has('bytestart') && params.has('byteend');
  } catch {
    return false;
  }
}

/**
 * Classifies a network response seen by the add-on.
 * response: { url, headers } where headers is an object or an array of { name, value }.
 * Returns { media, kind, protected }, kind being 'video', 'audio', 'hls', 'dash' or null.
 */
export function isMediaResponse(response, options = {}) {
  const none = { media: false, kind: null, protected: false };
  if (!response || typeof response.url !== 'string') return none;
  const url = response.url;
  const type = String(headerValue(response.headers, 'content-type') || '').split(';')[0].trim().toLowerCase();
  const length = Number(headerValue(response.headers, 'content-length'));
  const minimumBytes = Number.isFinite(options.minimumBytes) ? options.minimumBytes : 300 * 1024;
  const ext = extensionOf(url);
  if (adOrTracking.test(url) || youtubePieces.test(url) || isByteRangePiece(url)) return none;
  // Pieces of a stream (HLS .ts, DASH and CMAF segments) are not videos on their own.
  if (streamPieceTypes.includes(type) || streamPieceExtensions.includes(ext)) return none;

  const isProtected = protectedHints.test(url) || protectedHints.test(type);
  if (hlsTypes.includes(type) || ext === 'm3u8') return { media: true, kind: 'hls', protected: isProtected };
  if (type === 'application/dash+xml' || ext === 'mpd' || type === 'application/vnd.ms-sstr+xml') {
    return { media: true, kind: 'dash', protected: isProtected };
  }
  const isVideo = type.startsWith('video/');
  const isAudio = type.startsWith('audio/');
  if (!isVideo && !isAudio) return none;
  if (Number.isFinite(length) && length > 0 && length < minimumBytes) return none;
  return { media: true, kind: isVideo ? 'video' : 'audio', protected: isProtected };
}

/** A short readable name for a media address. Decodes first and shortens after, and never throws. */
export function displayName(url, max = 60) {
  const text = String(url ?? '');
  const raw = text.split(/[?#]/)[0].split('/').pop() || text;
  let name = raw;
  try {
    name = decodeURIComponent(raw);
  } catch {
    name = raw;
  }
  return name.length > max ? `${name.slice(0, Math.max(1, max - 1))}…` : name;
}

/** The media entry to offer by default: the newest stream playlist, otherwise the newest file. */
export function pickDefaultMedia(list) {
  const usable = (list || []).filter((item) => item && !item.protected);
  const streams = usable.filter((item) => item.kind === 'hls' || item.kind === 'dash');
  return streams.length ? streams[streams.length - 1] : usable[usable.length - 1];
}

/** A short readable size such as "512 B", "300 KB", "2.3 MB" or "1.0 GB"; empty when unknown. */
export function formatSize(bytes) {
  if (typeof bytes !== 'number' || !Number.isFinite(bytes) || bytes <= 0) return '';
  const wholeBytes = Math.round(bytes);
  if (wholeBytes < 1024) return `${wholeBytes} B`;
  const kilobytes = Math.round(bytes / 1024);
  if (kilobytes < 1024) return `${kilobytes} KB`;
  // The unit is chosen after rounding, so 1,048,575 bytes reads "1.0 MB", not "1024 KB".
  const megabytes = Math.round((bytes / 1048576) * 10) / 10;
  if (megabytes < 1024) return `${megabytes.toFixed(1)} MB`;
  return `${(bytes / 1073741824).toFixed(1)} GB`;
}

const mediaKinds = { video: 'Video', audio: 'Audio', hls: 'Stream', dash: 'Stream' };

/**
 * The parts of a media entry's label: { kind, format, size, name }. Parts that are unknown are empty.
 * A stream's size is left out, because the add-on only sees its playlist, which is a few KB.
 */
export function describeMedia(item, max = 60) {
  const entry = item || {};
  const stream = entry.kind === 'hls' || entry.kind === 'dash';
  return {
    kind: Object.hasOwn(mediaKinds, entry.kind) ? mediaKinds[entry.kind] : 'Media',
    format: stream ? entry.kind.toUpperCase() : extensionOf(entry.url).toUpperCase(),
    size: stream ? '' : formatSize(entry.size),
    name: displayName(entry.url, max),
  };
}

/** Where a box of `size` starts along one axis: `preferred`, kept `gap` inside `0..room`, start edge first. */
function startInside(preferred, size, room, gap) {
  const last = room - gap - size;
  if (last < gap) return gap;
  return Math.min(Math.max(preferred, gap), last);
}

/**
 * Where the on-page panel goes: the player's top-right corner, inset by `gap`, but always fully inside
 * the frame it is drawn in (a player inside an iframe is often wider than the iframe itself).
 * target is the player's bounding box, panel the panel's measured size, viewport the frame's size.
 */
export function panelPosition(target, panel, viewport, gap = 8) {
  const box = target || {};
  const width = panel?.width || 0;
  const height = panel?.height || 0;
  const view = { width: viewport?.width || 0, height: viewport?.height || 0 };
  const visible = box.width > 0 && box.bottom > 0 && box.top < view.height && box.right > 0 && box.left < view.width;
  return {
    visible,
    left: startInside(Math.min(box.right, view.width) - gap - width, width, view.width, gap),
    top: startInside(Math.max(box.top, 0) + gap, height, view.height, gap),
  };
}

/**
 * Where the panel's media menu goes. It opens below the panel when it fits there or when there is at
 * least as much room below as above, otherwise above. Its height is capped between 120 and 320px, it
 * lines up with the panel's right edge, and it stays fully inside the frame.
 */
export function menuPlacement(anchor, menu, viewport, gap = 8) {
  const box = anchor || {};
  const width = menu?.width || 0;
  const height = menu?.height || 0;
  const view = { width: viewport?.width || 0, height: viewport?.height || 0 };
  const below = view.height - box.bottom - 2 * gap;
  const above = box.top - 2 * gap;
  const up = height > below && above > below;
  const maxHeight = Math.min(320, Math.max(120, up ? above : below));
  const shown = Math.min(height, maxHeight);
  return {
    up,
    maxHeight,
    left: startInside(box.right - width, width, view.width, gap),
    top: startInside(up ? box.top - gap - shown : box.bottom + gap, shown, view.height, gap),
  };
}

const youtubeHosts = new Set(['youtube.com', 'www.youtube.com', 'm.youtube.com', 'music.youtube.com', 'youtube-nocookie.com', 'www.youtube-nocookie.com']);
const youtubeVideoID = /^[A-Za-z0-9_-]{11}$/;
const youtubePlaylistID = /^[A-Za-z0-9_-]{2,}$/;

/**
 * What a YouTube address points at, the same way the app reads it (YouTubeLinks.swift):
 * { type: 'video', id, url } with the canonical watch address, { type: 'playlist', id, url }, or null.
 */
export function youtubeLink(address) {
  if (typeof address !== 'string') return null;
  let url;
  try {
    url = new URL(address);
  } catch {
    return null;
  }
  if (url.protocol !== 'http:' && url.protocol !== 'https:') return null;
  const host = url.hostname.toLowerCase();
  const parts = url.pathname.split('/').filter(Boolean);
  const video = (id) => (youtubeVideoID.test(id || '') ? { type: 'video', id, url: `https://www.youtube.com/watch?v=${id}` } : null);
  const playlist = (id) => (youtubePlaylistID.test(id || '') ? { type: 'playlist', id, url: `https://www.youtube.com/playlist?list=${id}` } : null);
  if (host === 'youtu.be') return video(parts[0]);
  if (!youtubeHosts.has(host)) return null;
  const list = url.searchParams.get('list');
  switch (parts[0]) {
    case 'watch':
      return video(url.searchParams.get('v'));
    case 'playlist':
      return playlist(list);
    case 'embed':
      return parts[1] === 'videoseries' ? playlist(list) : video(parts[1]);
    case 'shorts':
    case 'live':
    case 'v':
      return video(parts[1]);
    default:
      return null;
  }
}

const facebookNumber = /^\d+$/;

/**
 * Whether an address is a Facebook video, the same way the app reads it (FacebookLinks.swift): watch pages,
 * a page's videos, reels, share links of videos and reels, the embedded player and fb.watch short links.
 * Returns { type: 'video', url } with the address minus its #part, or null.
 */
export function facebookVideoLink(address) {
  if (typeof address !== 'string') return null;
  let url;
  try {
    url = new URL(address);
  } catch {
    return null;
  }
  if (url.protocol !== 'http:' && url.protocol !== 'https:') return null;
  const host = url.hostname.toLowerCase();
  const parts = url.pathname.split('/').filter(Boolean);
  const has = (name) => Boolean(url.searchParams.get(name));
  let video = false;
  if (host === 'fb.watch') {
    video = parts.length > 0;
  } else if (host === 'facebook.com' || host.endsWith('.facebook.com')) {
    const path = parts.join('/');
    switch (parts[0]) {
      case 'watch':
        video = (path === 'watch' || path === 'watch/live') && has('v');
        break;
      case 'video.php':
        video = path === 'video.php' && has('v');
        break;
      case 'video':
        video = path === 'video/video.php' && has('v');
        break;
      case 'reel':
        video = facebookNumber.test(parts[1] || '');
        break;
      case 'share':
        video = parts.length > 2 && (parts[1] === 'v' || parts[1] === 'r');
        break;
      case 'plugins':
        video = path === 'plugins/video.php' && has('href');
        break;
      default:
        // A page's video: /{page}/videos/{id} or /{page}/videos/{title}/{id}.
        video = parts[1] === 'videos' && (facebookNumber.test(parts[2] || '') || facebookNumber.test(parts[3] || ''));
    }
  }
  if (!video) return null;
  url.hash = '';
  return { type: 'video', url: url.href };
}

/**
 * A video page the app downloads through yt-dlp: a YouTube video or playlist, or a Facebook video.
 * Returns { site, type, url, cookieUrl } or null. cookieUrl is the address whose sign-in goes along,
 * so a short link such as fb.watch still carries the Facebook sign-in.
 */
export function webVideoLink(address) {
  const youtube = youtubeLink(address);
  if (youtube) return { site: 'youtube', type: youtube.type, url: youtube.url, cookieUrl: 'https://www.youtube.com/' };
  const facebook = facebookVideoLink(address);
  if (facebook) return { site: 'facebook', type: facebook.type, url: facebook.url, cookieUrl: 'https://www.facebook.com/' };
  return null;
}

/** The YouTube qualities offered, by the names the app uses (VideoQuality raw values). */
export const videoQualities = [
  { value: 'best', label: 'Best available', detail: 'Highest quality' },
  { value: '1080', label: '1080p', detail: 'Full HD' },
  { value: '720', label: '720p', detail: 'HD' },
  { value: '480', label: '480p', detail: 'Smaller file' },
  { value: '360', label: '360p', detail: 'Smallest file' },
  { value: 'audio', label: 'Sound only', detail: 'M4A audio' },
];

/** The label of a quality; an unknown one reads as the best. */
export function qualityLabel(value) {
  return (videoQualities.find((quality) => quality.value === value) || videoQualities[0]).label;
}
