// cDownloader add-on service worker: takes over downloads, adds context menu items,
// spots video and audio on pages, and talks to the cDownloader app through the native helper.
import { shouldIntercept, isMediaResponse, pickDefaultMedia, youtubeLink } from './rules.js';

const HOST = 'com.cdownloader.host';
const CLICK_WINDOW_MS = 3000;
const MAX_MEDIA_PER_TAB = 30;

const defaultConfig = {
  integrationEnabled: true,
  extensions: ['zip', 'rar', '7z', 'dmg', 'pkg', 'exe', 'msi', 'iso', 'pdf', 'mp3', 'mp4', 'mkv', 'mov', 'avi', 'webm', 'm3u8'],
  dontCaptureSites: [],
  addressExceptions: [],
  skipModifier: 'alt',
  forceModifier: null,
  videoPanelEnabled: true,
  videoPanelTypes: ['mp4', 'webm', 'm4v', 'mov', 'mp3', 'm4a', 'm3u8'],
  videoPanelExcludedSites: [],
  minimumMediaKB: 300,
  webVideoQuality: 'best',
};

let config = { ...defaultConfig };
let lastClick = null;

// Chrome stops idle service workers, so settings are kept in storage and read back before any decision.
async function loadStoredConfig() {
  const { config: saved, enabledOverride } = await chrome.storage.local.get(['config', 'enabledOverride']);
  if (saved) config = { ...defaultConfig, ...saved };
  if (enabledOverride === false) config.integrationEnabled = false;
}
const ready = loadStoredConfig().catch(() => {});

// ---------------------------------------------------------------- native helper

function sendNative(message) {
  return new Promise((resolve) => {
    try {
      chrome.runtime.sendNativeMessage(HOST, message, (reply) => {
        if (chrome.runtime.lastError) {
          resolve({ ok: false, error: chrome.runtime.lastError.message });
        } else {
          resolve(reply || { ok: false, error: 'No reply' });
        }
      });
    } catch (error) {
      resolve({ ok: false, error: String(error) });
    }
  });
}

async function refreshConfig() {
  const reply = await sendNative({ type: 'getConfig' });
  await ready;
  if (reply && reply.ok && reply.config) {
    config = { ...defaultConfig, ...reply.config };
    await chrome.storage.local.set({ config: reply.config });
  }
  const { enabledOverride } = await chrome.storage.local.get('enabledOverride');
  if (enabledOverride === false) config.integrationEnabled = false;
  return reply && reply.ok;
}

async function cookieHeader(url) {
  try {
    const cookies = await chrome.cookies.getAll({ url });
    return cookies.map((cookie) => `${cookie.name}=${cookie.value}`).join('; ') || undefined;
  } catch {
    return undefined;
  }
}

async function describe(url, extra = {}) {
  return { url, cookies: await cookieHeader(url), userAgent: navigator.userAgent, ...extra };
}

async function sendToApp(downloads, extra = {}) {
  const list = downloads.filter((download) => /^(https?|ftp):/i.test(download.url));
  if (list.length === 0) return { ok: false, error: 'No downloadable links' };
  return sendNative({ type: 'add', downloads: list, ...extra });
}

// ---------------------------------------------------------------- taking over downloads

function modifiersFor(url) {
  if (!lastClick || Date.now() - lastClick.time > CLICK_WINDOW_MS) return { skip: false, force: false };
  if (lastClick.url && url && lastClick.url !== url) return { skip: false, force: false };
  const held = (name) => Boolean(name) && Boolean(lastClick.keys[name]);
  return { skip: held(config.skipModifier), force: held(config.forceModifier) };
}

chrome.downloads.onDeterminingFilename.addListener((item, suggest) => {
  if (item.byExtensionId === chrome.runtime.id || item.state !== 'in_progress') {
    suggest();
    return false;
  }
  (async () => {
    await ready;
    const url = item.finalUrl || item.url;
    const keys = modifiersFor(item.url);
    const takeOver = shouldIntercept(
      { url, filename: item.filename, mime: item.mime, skipKey: keys.skip, forceKey: keys.force },
      config,
    );
    if (!takeOver) {
      suggest();
      return;
    }
    const name = (item.filename || '').split(/[\\/]/).pop() || undefined;
    const reply = await sendToApp([
      await describe(url, {
        referer: item.referrer || undefined,
        fileName: name,
        mimeType: item.mime || undefined,
        fileSize: item.fileSize > 0 ? item.fileSize : undefined,
        kind: /mpegurl/i.test(item.mime || '') || /\.m3u8($|[?#])/i.test(url) ? 'hls' : undefined,
      }),
    ]);
    suggest();
    if (reply.ok) {
      try {
        await chrome.downloads.cancel(item.id);
        await chrome.downloads.erase({ id: item.id });
      } catch {
        // Already gone.
      }
    }
  })();
  return true;
});

// ---------------------------------------------------------------- context menus

function createMenus() {
  chrome.contextMenus.removeAll(() => {
    chrome.contextMenus.create({ id: 'cdownloader-link', title: 'Download with cDownloader', contexts: ['link'] });
    chrome.contextMenus.create({ id: 'cdownloader-selection', title: 'Download selected links with cDownloader', contexts: ['selection'] });
    chrome.contextMenus.create({ id: 'cdownloader-page', title: 'Download all links with cDownloader', contexts: ['page'] });
    chrome.contextMenus.create({ id: 'cdownloader-media', title: 'Download this media with cDownloader', contexts: ['video', 'audio'] });
  });
}

async function collectLinks(tabId, frameId, selectionOnly) {
  try {
    const reply = await chrome.tabs.sendMessage(tabId, { type: 'collectLinks', selectionOnly }, { frameId });
    return Array.isArray(reply) ? reply : [];
  } catch {
    return [];
  }
}

chrome.contextMenus.onClicked.addListener(async (info, tab) => {
  const referer = info.pageUrl || tab?.url;
  if (info.menuItemId === 'cdownloader-link' && info.linkUrl) {
    // A YouTube link goes over as its main address, so the YouTube sign-in cookies travel with it.
    const youtube = youtubeLink(info.linkUrl);
    await sendToApp([await describe(youtube ? youtube.url : info.linkUrl, { referer, kind: youtube ? 'youtube' : undefined })]);
  } else if (info.menuItemId === 'cdownloader-selection' || info.menuItemId === 'cdownloader-page') {
    const links = await collectLinks(tab.id, info.frameId ?? 0, info.menuItemId === 'cdownloader-selection');
    const downloads = await Promise.all(links.map((link) => describe(link.url, { referer, fileName: undefined })));
    await sendToApp(downloads, { showList: true, pageURL: referer });
  } else if (info.menuItemId === 'cdownloader-media') {
    // YouTube's player plays from a blob, so the video page itself is what gets downloaded.
    const youtube = [info.frameUrl, info.pageUrl].map(youtubeLink).find((link) => link?.type === 'video');
    if (youtube) {
      await sendToApp([await describe(youtube.url, { referer, kind: 'youtube' })]);
      return;
    }
    let source = info.srcUrl;
    if (!source || source.startsWith('blob:')) {
      const best = pickDefaultMedia(await mediaForTab(tab.id));
      source = best?.url;
    }
    if (source) await sendToApp([await describe(source, { referer, kind: /\.m3u8(\?|$)/i.test(source) ? 'hls' : undefined })]);
  }
});

// ---------------------------------------------------------------- media detection

async function mediaForTab(tabId) {
  const key = `media:${tabId}`;
  const stored = await chrome.storage.session.get(key);
  return stored[key] || [];
}

async function rememberMedia(tabId, item) {
  const key = `media:${tabId}`;
  const list = (await mediaForTab(tabId)).filter((existing) => existing.url !== item.url);
  list.push(item);
  await chrome.storage.session.set({ [key]: list.slice(-MAX_MEDIA_PER_TAB) });
  const count = list.filter((entry) => !entry.protected).length;
  chrome.action.setBadgeText({ tabId, text: count ? String(count) : '' });
  chrome.action.setBadgeBackgroundColor({ tabId, color: '#2563eb' });
}

chrome.webRequest.onHeadersReceived.addListener(
  (details) => {
    if (details.tabId < 0 || !config.videoPanelEnabled) return;
    const result = isMediaResponse(
      { url: details.url, headers: details.responseHeaders },
      { minimumBytes: (config.minimumMediaKB || 300) * 1024 },
    );
    if (!result.media) return;
    const header = (name) => details.responseHeaders?.find((h) => h.name.toLowerCase() === name)?.value;
    const item = {
      url: details.url,
      kind: result.kind,
      protected: result.protected,
      size: Number(header('content-length')) || undefined,
      contentType: header('content-type') || undefined,
      time: Date.now(),
    };
    rememberMedia(details.tabId, item).then(() => {
      chrome.tabs.sendMessage(details.tabId, { type: 'mediaFound', item, config }).catch(() => {});
    });
  },
  { urls: ['<all_urls>'], types: ['media', 'xmlhttprequest', 'object', 'other'] },
  ['responseHeaders'],
);

chrome.tabs.onUpdated.addListener((tabId, change) => {
  if (change.status === 'loading' && change.url) {
    chrome.storage.session.remove(`media:${tabId}`);
    chrome.action.setBadgeText({ tabId, text: '' });
  }
});

chrome.tabs.onRemoved.addListener((tabId) => {
  chrome.storage.session.remove(`media:${tabId}`);
});

// ---------------------------------------------------------------- messages from page scripts and the popup

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  (async () => {
    switch (message?.type) {
      case 'click':
        lastClick = { url: message.url, keys: message.keys || {}, time: Date.now() };
        sendResponse({ ok: true });
        break;
      case 'mediaDownload': {
        const referer = sender.tab?.url;
        const item = message.item;
        const kind = item.kind === 'hls' || item.kind === 'youtube' ? item.kind : undefined;
        sendResponse(await sendToApp([await describe(item.url, { referer, kind, quality: item.kind === 'youtube' ? item.quality : undefined })]));
        break;
      }
      case 'getState': {
        const tabId = message.tabId;
        const connected = await refreshConfig();
        sendResponse({ connected, config, media: tabId != null ? await mediaForTab(tabId) : [] });
        break;
      }
      case 'setEnabled':
        await chrome.storage.local.set({ enabledOverride: Boolean(message.enabled) });
        await refreshConfig();
        config.integrationEnabled = Boolean(message.enabled) && config.integrationEnabled;
        sendResponse({ ok: true, config });
        break;
      case 'openApp':
        sendResponse(await sendNative({ type: 'showWindow' }));
        break;
      case 'getConfig':
        // Right after the worker wakes, the saved settings are still loading; answer with them, not the defaults.
        await ready;
        sendResponse(config);
        break;
      default:
        sendResponse({ ok: false });
    }
  })();
  return true;
});

chrome.runtime.onInstalled.addListener(() => {
  createMenus();
  refreshConfig();
});

chrome.runtime.onStartup.addListener(() => {
  createMenus();
  refreshConfig();
});

refreshConfig();
