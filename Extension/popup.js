// Popup: connection status, the on/off switch, and media found on the current tab.
import { describeMedia, youtubeLink, qualityLabel } from './rules.js';

const statusBadge = document.getElementById('status');
const statusText = document.getElementById('status-text');
const notice = document.getElementById('notice');
const enabledBox = document.getElementById('enabled');
const toggle = document.getElementById('enabled-toggle');
const enabledIcon = document.getElementById('enabled-icon');
const enabledDetail = document.getElementById('enabled-detail');
const skipHint = document.getElementById('skip-hint');
const skipKey = document.getElementById('skip-key');
const list = document.getElementById('media');
const count = document.getElementById('media-count');

// Follow the Mac's light or dark appearance.
const darkQuery = matchMedia('(prefers-color-scheme: dark)');
const applyTheme = () => {
  document.documentElement.dataset.theme = darkQuery.matches ? 'dark' : 'light';
};
applyTheme();
darkQuery.addEventListener('change', applyTheme);

const svg = (body, size = '') => `<svg class="icon ${size}" viewBox="0 0 24 24" aria-hidden="true">${body}</svg>`;
const icons = {
  video: svg('<rect x="3" y="5" width="18" height="14" rx="2"/><path d="m10 9 5 3-5 3z"/>'),
  audio: svg('<path d="M9 18V5l12-2v13"/><circle cx="6" cy="18" r="3"/><circle cx="18" cy="16" r="3"/>'),
  stream: svg('<path d="M2 12h3l3-8 4 16 3-8h7"/>'),
  check: svg('<path d="m5 12 5 5L20 7"/>', 'sm'),
  lock: svg('<rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/>', 'sm'),
};

// The key that lets the browser keep a download, as the Mac keyboard labels it.
const keyNames = { alt: 'Option ⌥', shift: 'Shift ⇧', ctrl: 'Control ⌃', meta: 'Command ⌘' };

function renderStatus(connected) {
  statusText.textContent = connected ? 'Connected' : 'Not connected';
  statusBadge.querySelector('.dot').className = `dot ${connected ? 'success' : 'error'}`;
  notice.hidden = connected;
}

function renderEnabled() {
  const on = enabledBox.checked;
  toggle.classList.toggle('is-on', on);
  enabledIcon.classList.toggle('gray', !on);
  enabledDetail.textContent = on ? 'Downloads open in cDownloader' : 'Downloads stay in the browser';
}

function setButton(button, text, icon = '') {
  button.innerHTML = icon;
  button.append(text);
}

function row(item) {
  const info = describeMedia(item);
  const element = document.createElement('div');
  element.className = 'list-row';
  const tile = item.protected ? 'gray' : item.kind === 'audio' ? 'orange' : item.kind === 'hls' || item.kind === 'dash' ? 'green' : '';
  const icon = icons[item.kind === 'audio' ? 'audio' : item.kind === 'video' ? 'video' : 'stream'];
  element.innerHTML = `<span class="licon ${tile}">${icon}</span><div class="ltext"><div class="lname"></div><span></span></div>`;
  const text = element.querySelector('.ltext');
  text.title = item.url;
  text.querySelector('.lname').textContent = info.name || item.url;
  text.querySelector('span').textContent = [info.kind, info.format, info.size].filter(Boolean).join(' · ');
  if (item.protected) {
    const badge = document.createElement('span');
    badge.className = 'badge';
    badge.title = 'This media is copy-protected (DRM), so it cannot be downloaded.';
    setButton(badge, 'Protected', icons.lock);
    element.appendChild(badge);
    return element;
  }
  element.appendChild(sendButton(item, 'Download', `Download ${info.name || info.kind}`));
  return element;
}

// The YouTube video or playlist open in this tab; the app downloads it through yt-dlp at its default quality.
function youtubeRow(link, title, quality) {
  const element = document.createElement('div');
  element.className = 'list-row';
  element.innerHTML = `<span class="licon red">${icons.video}</span><div class="ltext"><div class="lname"></div><span></span></div>`;
  const text = element.querySelector('.ltext');
  text.title = link.url;
  const cleanTitle = String(title || '').replace(/^\(\d+\)\s*/, '').replace(/\s+-\s+YouTube$/, '');
  const playlist = link.type === 'playlist';
  text.querySelector('.lname').textContent = cleanTitle || (playlist ? 'YouTube playlist' : 'YouTube video');
  text.querySelector('span').textContent = playlist ? 'YouTube playlist · Every video' : `YouTube · ${qualityLabel(quality)}`;
  element.appendChild(sendButton({ url: link.url, kind: 'youtube' }, playlist ? 'Add all' : 'Download', playlist ? 'Add every video of this playlist' : 'Download this YouTube video'));
  return element;
}

function sendButton(item, label, accessibleName) {
  const button = document.createElement('button');
  button.type = 'button';
  button.className = 'btn plain mini';
  button.setAttribute('aria-label', accessibleName);
  button.textContent = label;
  let busy = false;
  button.addEventListener('click', async () => {
    if (busy) return;
    busy = true;
    button.textContent = 'Sending…';
    const reply = await chrome.runtime.sendMessage({ type: 'mediaDownload', item }).catch(() => null);
    if (!reply?.ok) {
      button.textContent = 'Try again';
      busy = false;
      return;
    }
    setButton(button, 'Sent', icons.check);
    setTimeout(() => {
      busy = false;
      button.textContent = label;
    }, 2500);
  });
  return button;
}

async function load() {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  const state = await chrome.runtime.sendMessage({ type: 'getState', tabId: tab?.id }).catch(() => null);
  renderStatus(Boolean(state?.connected));
  if (!state) {
    enabledBox.disabled = true;
    toggle.classList.add('is-disabled');
    enabledIcon.classList.add('gray');
    enabledDetail.textContent = 'Status unavailable';
    return;
  }
  enabledBox.checked = Boolean(state.config.integrationEnabled);
  renderEnabled();
  const key = keyNames[state.config.skipModifier];
  skipHint.hidden = !key;
  if (key) skipKey.textContent = key;
  const youtube = youtubeLink(tab?.url);
  const rows = [...(youtube ? [youtubeRow(youtube, tab.title, state.config.webVideoQuality)] : []), ...[...state.media].reverse().map(row)];
  if (rows.length) {
    list.replaceChildren(...rows);
    count.textContent = String(rows.length);
    count.hidden = false;
  }
}

enabledBox.addEventListener('change', () => {
  renderEnabled();
  chrome.runtime.sendMessage({ type: 'setEnabled', enabled: enabledBox.checked }).catch(() => {});
});
toggle.addEventListener('pointerdown', () => toggle.classList.add('is-pressed'));
['pointerup', 'pointerleave'].forEach((name) => toggle.addEventListener(name, () => toggle.classList.remove('is-pressed')));
document.getElementById('open').addEventListener('click', () => chrome.runtime.sendMessage({ type: 'openApp' }).catch(() => {}));
load();
