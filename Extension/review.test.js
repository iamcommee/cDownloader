// Regression tests written from the code review findings CR-08, CR-09 and CR-10.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { isMediaResponse, displayName, pickDefaultMedia } from './rules.js';

const big = String(800 * 1024);

// CR-09: stream pieces are not offered as videos, and the playlist wins.
for (const [label, response] of [
  ['mpeg-ts piece', { url: 'https://v.example/seg-0001.ts', headers: { 'content-type': 'video/MP2T', 'content-length': big } }],
  ['ts by name', { url: 'https://v.example/chunk_12.ts?token=1', headers: { 'content-type': 'video/mp4', 'content-length': big } }],
  ['fmp4 piece', { url: 'https://v.example/v/seg-4.m4s', headers: { 'content-type': 'video/iso.segment', 'content-length': big } }],
]) {
  test(`CR-09 isMediaResponse ignores ${label}`, () => {
    assert.equal(isMediaResponse(response, { minimumBytes: 300 * 1024 }).media, false);
  });
}

test('CR-09 the playlist is the default choice over plain files', () => {
  const list = [
    { url: 'https://v.example/master.m3u8', kind: 'hls' },
    { url: 'https://v.example/preview.mp4', kind: 'video' },
    { url: 'https://v.example/drm.mpd', kind: 'dash', protected: true },
  ];
  assert.equal(pickDefaultMedia(list).url, 'https://v.example/master.m3u8');
  assert.equal(pickDefaultMedia([{ url: 'https://v.example/a.mp4', kind: 'video' }]).url, 'https://v.example/a.mp4');
  assert.equal(pickDefaultMedia([{ url: 'x', kind: 'dash', protected: true }]), undefined);
});

// CR-10: names that are cut in the middle of an escape never throw.
test('CR-10 displayName survives cut and malformed escapes', () => {
  const longName = 'https://v.example/' + '%E4%B8%AD'.repeat(30) + '.mp4';
  assert.doesNotThrow(() => displayName(longName, 40));
  assert.equal(displayName('https://v.example/bad%E4%B8.mp4'), 'bad%E4%B8.mp4');
  assert.equal(displayName('https://v.example/a%20b.mp4?x=1'), 'a b.mp4');
  assert.ok(displayName(longName, 10).length <= 10);
});

// CR-08: after the service worker wakes up, saved settings decide before the app answers.
function fakeChrome({ stored, appConfig, replyDelay = 30, storageDelay = 0 }) {
  const listeners = {};
  const event = (name) => ({ addListener: (fn) => { listeners[name] = fn; } });
  const state = { cancelled: [], added: [], local: { ...stored } };
  const chrome = {
    runtime: {
      id: 'ext',
      lastError: undefined,
      sendNativeMessage: (host, message, callback) => {
        setTimeout(() => {
          if (message.type === 'getConfig') callback({ ok: true, config: appConfig });
          else if (message.type === 'add') { state.added.push(message); callback({ ok: true }); }
          else callback({ ok: true });
        }, replyDelay);
      },
      onMessage: event('onMessage'),
      onInstalled: event('onInstalled'),
      onStartup: event('onStartup'),
    },
    storage: {
      local: {
        get: async (key) => {
          if (storageDelay) await new Promise((resolve) => setTimeout(resolve, storageDelay));
          return key == null ? { ...state.local } : Object.fromEntries([].concat(key).filter((k) => k in state.local).map((k) => [k, state.local[k]]));
        },
        set: async (values) => { Object.assign(state.local, values); },
      },
      session: { get: async () => ({}), set: async () => {}, remove: async () => {} },
    },
    downloads: {
      onDeterminingFilename: event('onDeterminingFilename'),
      cancel: async (id) => { state.cancelled.push(id); },
      erase: async () => {},
    },
    contextMenus: { onClicked: event('onClicked'), removeAll: (callback) => callback && callback(), create: () => {} },
    webRequest: { onHeadersReceived: event('onHeadersReceived') },
    tabs: { onUpdated: event('onUpdated'), onRemoved: event('onRemoved'), sendMessage: async () => {} },
    action: { setBadgeText: () => {}, setBadgeBackgroundColor: () => {} },
    cookies: { getAll: async () => [] },
  };
  return { chrome, listeners, state };
}

async function wakeAndDownload(fake, caseName, url) {
  globalThis.chrome = fake.chrome;
  await import(`./background.js?case=${caseName}`);
  let suggested = false;
  const item = { id: 7, url, finalUrl: url, filename: '', mime: 'application/zip', state: 'in_progress', fileSize: 1000 };
  fake.listeners.onDeterminingFilename(item, () => { suggested = true; });
  await new Promise((resolve) => setTimeout(resolve, 300));
  return suggested;
}

const appConfig = { integrationEnabled: true, extensions: ['zip'], dontCaptureSites: [], addressExceptions: [], videoPanelEnabled: true, minimumMediaKB: 300 };

test('CR-08 a switched-off add-on stays off right after waking up', async () => {
  const fake = fakeChrome({ stored: { enabledOverride: false }, appConfig });
  const suggested = await wakeAndDownload(fake, 'off', 'https://files.example/a.zip');
  assert.equal(suggested, true);
  assert.deepEqual(fake.state.cancelled, []);
  assert.deepEqual(fake.state.added, []);
});

test('CR-08 excluded sites saved from the app are honored right after waking up', async () => {
  const saved = { ...appConfig, dontCaptureSites: ['*.example'] };
  const fake = fakeChrome({ stored: { config: saved }, appConfig: saved, replyDelay: 1000 });
  const suggested = await wakeAndDownload(fake, 'excluded', 'https://files.example/a.zip');
  assert.equal(suggested, true);
  assert.deepEqual(fake.state.cancelled, []);
});

// T17-CR02: right after the service worker wakes up, pages asking for the settings get the saved ones, not the defaults.
test('T17-CR02 getConfig waits for the saved settings', async () => {
  const saved = { ...appConfig, webVideoQuality: '720', videoPanelExcludedSites: ['*.skip.example'] };
  const fake = fakeChrome({ stored: { config: saved }, appConfig: saved, replyDelay: 1000, storageDelay: 50 });
  globalThis.chrome = fake.chrome;
  await import('./background.js?case=getconfig');
  const reply = await new Promise((resolve) => fake.listeners.onMessage({ type: 'getConfig' }, {}, resolve));
  assert.equal(reply.webVideoQuality, '720');
  assert.deepEqual(reply.videoPanelExcludedSites, ['*.skip.example']);
});
