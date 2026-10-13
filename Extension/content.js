// cDownloader content script: remembers which keys were held when a link was clicked,
// collects links for "download all/selected links", and shows the "Download this video" panel.
(async () => {
  if (window.__cDownloaderContent) return;
  window.__cDownloaderContent = true;
  // Content scripts cannot use `import`, so the shared rules are loaded as a module at run time.
  const rules = await import(chrome.runtime.getURL('rules.js'));

  let pageUsesDRM = false;
  const media = [];
  let panelHost = null;
  let panelTarget = null;

  // ------------------------------------------------------------ clicks and modifier keys

  document.addEventListener(
    'click',
    (event) => {
      const link = event.target instanceof Element ? event.target.closest('a[href]') : null;
      if (!link) return;
      chrome.runtime
        .sendMessage({
          type: 'click',
          url: link.href,
          keys: { alt: event.altKey, shift: event.shiftKey, ctrl: event.ctrlKey, meta: event.metaKey },
        })
        .catch(() => {});
    },
    true,
  );

  // ------------------------------------------------------------ link collection

  function linksIn(root, selection) {
    const found = new Map();
    const add = (url, text) => {
      if (!url || !/^(https?|ftp):/i.test(url)) return;
      const clean = url.split('#')[0];
      if (!found.has(clean)) found.set(clean, { url: clean, text: (text || '').trim().slice(0, 200) });
    };
    const inSelection = (node) => !selection || selection.some((range) => range.intersectsNode(node));
    root.querySelectorAll('a[href], area[href]').forEach((node) => inSelection(node) && add(node.href, node.textContent));
    root.querySelectorAll('img[src], video[src], audio[src], source[src]').forEach((node) => inSelection(node) && add(node.src, node.alt || ''));
    return [...found.values()];
  }

  chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
    if (message?.type === 'collectLinks') {
      let ranges = null;
      if (message.selectionOnly) {
        const selection = window.getSelection();
        ranges = [];
        for (let index = 0; selection && index < selection.rangeCount; index += 1) ranges.push(selection.getRangeAt(index));
      }
      sendResponse(linksIn(document, ranges));
      return false;
    }
    if (message?.type === 'mediaFound') {
      noteMedia(message.item, message.config);
      sendResponse({ ok: true });
      return false;
    }
    return false;
  });

  // ------------------------------------------------------------ DRM hint from the page world

  window.addEventListener('message', (event) => {
    if (event.source === window && event.data?.source === 'cdownloader-page' && event.data.type === 'drm') {
      pageUsesDRM = true;
      renderPanel();
    }
  });

  // ------------------------------------------------------------ download panel

  function siteExcluded(config) {
    const host = location.hostname.toLowerCase();
    return (config?.videoPanelExcludedSites || []).some((pattern) => {
      const regex = new RegExp('^' + String(pattern).toLowerCase().split('*').map((part) => part.replace(/[.+?^${}()|[\]\\]/g, '\\$&')).join('.*') + '$');
      return regex.test(host);
    });
  }

  function noteMedia(item, config) {
    if (window.top !== window && !document.querySelector('video, audio')) return;
    if (!config?.videoPanelEnabled || siteExcluded(config)) return;
    const isNew = !media.some((existing) => existing.url === item.url);
    if (isNew) media.push(item);
    // Streaming pages report the same address many times; only a new one, or a panel still to be built, needs a render.
    if (isNew || !panelHost) renderPanel();
  }

  // The box the panel lines up with. YouTube parks its <video> above the player until playback starts and
  // shows a picture in its place, so there the player box is what the person sees.
  function playerBox(element) {
    return element.closest('.html5-video-player') || element;
  }

  function largestPlayer() {
    let best = null;
    let bestArea = 0;
    document.querySelectorAll('video, audio').forEach((element) => {
      const anchor = playerBox(element);
      const box = anchor.getBoundingClientRect();
      const area = box.width * box.height;
      if (area > bestArea && box.width > 120 && box.height > 30) {
        best = anchor;
        bestArea = area;
      }
    });
    return best;
  }

  // Labels come from the shared rules, so the popup and the panel describe media the same way.
  function detailOf(item) {
    const info = rules.describeMedia(item);
    return [info.kind, info.format, info.size].filter(Boolean).join(' · ');
  }

  function shortLabel(item) {
    const info = rules.describeMedia(item, 40);
    return [info.format || info.kind, info.size || info.name].filter(Boolean).join(' · ');
  }

  // The panel's look comes from the liquidglass design system: the token file ships byte-identical and is
  // scoped to the panel's shadow root here (":root" becomes ":host"), so the page's styles never leak in.
  // The host covers the frame without catching clicks; the panel and its menu are placed inside it by
  // rules.panelPosition and rules.menuPlacement, which keep both fully inside the frame.
  let panelCSS = null;
  function loadPanelCSS() {
    if (!panelCSS) {
      const read = (path) => fetch(chrome.runtime.getURL(path)).then((response) => response.text());
      panelCSS = Promise.all([read('styles/liquidglass-tokens.css'), read('styles/liquidglass-components.css')]).catch((error) => {
        panelCSS = null;
        throw error;
      }).then(([tokens, components]) => {
        const scoped = tokens
          .replaceAll(':root[data-theme="light"]', ':host([data-theme="light"])')
          .replaceAll(':root[data-theme="dark"]', ':host([data-theme="dark"])')
          .replaceAll(':root', ':host');
        const layout = `
          :host { all: initial; }
          * { box-sizing: border-box; margin: 0; padding: 0; }
          [hidden] { display: none !important; }
          svg { display: block; flex-shrink: 0; }
          button { font: inherit; color: inherit; }
          :focus-visible { outline: 2px solid var(--color-accent); outline-offset: 2px; }
          .panel, .menu { position: absolute; top: 0; left: 0; pointer-events: auto; font-family: var(--font-text); color: var(--color-ink); line-height: 1.3; -webkit-font-smoothing: antialiased; }
          .panel { display: flex; align-items: center; gap: var(--space-2); width: max-content; max-width: calc(100% - 2 * var(--space-2)); }
          .go { flex-shrink: 0; }
          .go.is-protected:disabled { opacity: 1; color: var(--color-ink-secondary); }
          .pick { flex: 0 1 auto; min-width: 0; max-width: 220px; min-height: 32px; padding: 0 var(--space-2) 0 var(--space-3); gap: var(--space-1); font-size: var(--text-subhead); letter-spacing: var(--tracking-subhead); }
          .pick .label { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
          .close { flex-shrink: 0; }
          .menu { width: min(320px, calc(100% - 2 * var(--space-2))); }
          .menu-list { display: flex; flex-direction: column; min-height: 0; overflow-y: auto; overscroll-behavior: contain; }
          .menu-head { padding: var(--space-2) var(--space-3) var(--space-1); font-size: var(--text-footnote); letter-spacing: var(--tracking-footnote); font-weight: 600; color: var(--color-ink-secondary); }
          .menu-item { flex-shrink: 0; width: 100%; min-height: 52px; padding: var(--space-2) var(--space-3); }
          .menu-item[aria-selected="true"] { background: var(--color-fill-3); }
          .menu-item[aria-selected="false"] .mark { visibility: hidden; }
          .mtext { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 2px; }
          .mname, .mdetail { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
          .mname { font-size: var(--text-subhead); letter-spacing: var(--tracking-subhead); font-weight: 500; }
          .mdetail { font-size: var(--text-footnote); letter-spacing: var(--tracking-footnote); color: var(--color-ink-secondary); }`;
        return `${scoped}\n${components}\n${layout}`;
      });
    }
    return panelCSS;
  }

  const svg = (body, size = '') => `<svg class="icon ${size}" viewBox="0 0 24 24" aria-hidden="true">${body}</svg>`;
  const panelIcons = {
    down: svg('<path d="M12 4v12M7 11l5 5 5-5M5 20h14"/>', 'sm'),
    check: svg('<path d="m5 12 5 5L20 7"/>', 'sm'),
    alert: svg('<circle cx="12" cy="12" r="9"/><path d="M12 8v5M12 16h.01"/>', 'sm'),
    lock: svg('<rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/>', 'sm'),
    chev: svg('<path d="m6 9 6 6 6-6"/>', 'sm chev'),
    close: svg('<path d="M6 6l12 12M18 6 6 18"/>'),
    mark: svg('<path d="m5 12 5 5L20 7"/>', 'sm mark'),
    video: svg('<rect x="3" y="5" width="18" height="14" rx="2"/><path d="m10 9 5 3-5 3z"/>'),
    audio: svg('<path d="M9 18V5l12-2v13"/><circle cx="6" cy="18" r="3"/><circle cx="18" cy="16" r="3"/>'),
    stream: svg('<path d="M2 12h3l3-8 4 16 3-8h7"/>'),
  };
  const iconFor = (item) => (item.kind === 'audio' ? 'audio' : item.kind === 'video' ? 'video' : 'stream');

  let chosenKey = null;
  let currentChoice = null;
  let renderedHref = null;
  let youtubeConfig = null;
  let goStatus = null;
  let goStatusTimer = 0;
  let dismissedOn = null;
  let menuSignature = '';
  let placeTimer = 0;
  const sizeWatcher = typeof ResizeObserver === 'function' ? new ResizeObserver(() => place()) : null;

  function buildPanel() {
    panelHost = document.createElement('div');
    panelHost.setAttribute('data-theme', 'dark');
    panelHost.style.cssText = 'position:fixed;z-index:2147483647;top:0;left:0;width:100%;height:100%;pointer-events:none;display:block;';
    const shadow = panelHost.attachShadow({ mode: 'open' });
    const style = document.createElement('style');
    const panel = document.createElement('div');
    panel.className = 'panel';
    panel.setAttribute('role', 'toolbar');
    panel.setAttribute('aria-label', 'cDownloader');
    panel.innerHTML = `
      <button type="button" class="btn mini glass tinted is-interactive go"></button>
      <button type="button" class="glass is-interactive select mini pick" aria-haspopup="listbox" aria-expanded="false" hidden><span class="label"></span>${panelIcons.chev}</button>
      <button type="button" class="glass is-interactive btn-icon mini close" aria-label="Hide" title="Hide">${panelIcons.close}</button>`;
    const menu = document.createElement('div');
    menu.className = 'glass thick menu';
    menu.setAttribute('role', 'listbox');
    menu.setAttribute('aria-label', 'Media on this page');
    menu.hidden = true;
    shadow.append(style, panel, menu);

    shadow.querySelector('.close').addEventListener('click', dismissPanel);
    shadow.querySelector('.pick').addEventListener('click', () => setMenuOpen(menu.hidden));
    shadow.querySelector('.go').addEventListener('click', sendChoice);
    window.addEventListener('scroll', place, true);
    window.addEventListener('resize', place);
    document.addEventListener('pointerdown', closeMenuOutside, true);
    document.addEventListener('keydown', closeMenuOnEscape, true);
    sizeWatcher?.observe(panel);
    if (panelTarget) sizeWatcher?.observe(panelTarget);
    // Players also move without scrolling or resizing (a banner loads above, playback starts), so the
    // position is checked twice a second as well.
    placeTimer = setInterval(place, 500);
    // The panel joins the page only once its styles are in, so it never shows (or fades in from) unstyled buttons.
    loadPanelCSS().then((css) => {
      style.textContent = css;
      if (panelHost?.shadowRoot !== shadow) return;
      document.documentElement.appendChild(panelHost);
      place();
    }).catch(() => {
      // The styles could not be read (for example while the add-on reloads): start over on the next render.
      if (panelHost?.shadowRoot === shadow) removePanel();
    });
  }

  // "Hide" keeps the panel away for the rest of this page; the popup still lists what was found.
  function dismissPanel() {
    dismissedOn = location.href;
    removePanel();
  }

  function removePanel() {
    window.removeEventListener('scroll', place, true);
    window.removeEventListener('resize', place);
    document.removeEventListener('pointerdown', closeMenuOutside, true);
    document.removeEventListener('keydown', closeMenuOnEscape, true);
    sizeWatcher?.disconnect();
    clearInterval(placeTimer);
    panelHost.remove();
    panelHost = null;
    panelTarget = null;
    menuSignature = '';
  }

  function setMenuOpen(open) {
    if (!panelHost) return;
    const shadow = panelHost.shadowRoot;
    shadow.querySelector('.menu').hidden = !open;
    shadow.querySelector('.pick').setAttribute('aria-expanded', String(open));
    if (open) placeMenu();
  }

  function closeMenuOutside(event) {
    if (panelHost && !event.composedPath().includes(panelHost)) setMenuOpen(false);
  }

  function closeMenuOnEscape(event) {
    if (event.key !== 'Escape' || !panelHost || panelHost.shadowRoot.querySelector('.menu').hidden) return;
    event.stopPropagation();
    setMenuOpen(false);
    panelHost.shadowRoot.querySelector('.pick').focus();
  }

  async function sendChoice() {
    const item = currentChoice?.item;
    if (!item || item.protected || goStatus?.busy) return;
    clearTimeout(goStatusTimer);
    goStatus = { icon: 'down', text: 'Sending…', busy: true };
    renderPanel();
    const reply = await chrome.runtime.sendMessage({ type: 'mediaDownload', item }).catch(() => null);
    goStatus = reply?.ok ? { icon: 'check', text: 'Sent to cDownloader' } : { icon: 'alert', text: 'Couldn’t reach cDownloader' };
    renderPanel();
    goStatusTimer = setTimeout(() => {
      goStatus = null;
      renderPanel();
    }, 2500);
  }

  // A YouTube video page offers qualities (yt-dlp in the app does the download); other pages offer the media
  // found on them. Each option: { key, name, detail, short, icon, audio, title, item }.
  function youtubeVideo() {
    const link = rules.youtubeLink(location.href);
    return link?.type === 'video' ? link : null;
  }

  function panelChoices() {
    const video = youtubeVideo();
    if (video) {
      const preferred = youtubeConfig?.webVideoQuality;
      return {
        heading: 'Quality',
        fallbackKey: rules.videoQualities.some((quality) => quality.value === preferred) ? preferred : 'best',
        options: rules.videoQualities.map((quality) => ({
          key: quality.value,
          name: quality.label,
          detail: quality.detail,
          short: quality.label,
          icon: quality.value === 'audio' ? 'audio' : 'video',
          audio: quality.value === 'audio',
          title: video.url,
          item: { url: video.url, kind: 'youtube', quality: quality.value },
        })),
      };
    }
    const usable = media.filter((item) => !item.protected);
    return {
      heading: `${usable.length} found on this page`,
      fallbackKey: rules.pickDefaultMedia(usable)?.url,
      options: usable.map((item) => ({
        key: item.url,
        name: rules.describeMedia(item).name || item.url,
        detail: detailOf(item),
        short: shortLabel(item),
        icon: iconFor(item),
        audio: item.kind === 'audio',
        title: item.url,
        item,
      })),
    };
  }

  function menuOption(choice, selected) {
    const option = document.createElement('button');
    option.type = 'button';
    option.className = 'menu-item';
    option.title = choice.title;
    option.setAttribute('role', 'option');
    option.setAttribute('aria-selected', String(selected));
    option.innerHTML = `${panelIcons[choice.icon]}<span class="mtext"><span class="mname"></span><span class="mdetail"></span></span>${panelIcons.mark}`;
    option.querySelector('.mname').textContent = choice.name;
    option.querySelector('.mdetail').textContent = choice.detail;
    option.addEventListener('click', () => {
      chosenKey = choice.key;
      setMenuOpen(false);
      renderPanel();
      panelHost?.shadowRoot.querySelector('.pick').focus();
    });
    return option;
  }

  function renderGo(choice, onlyProtected) {
    const go = panelHost.shadowRoot.querySelector('.go');
    let state = { icon: 'down', text: choice?.audio ? 'Download audio' : 'Download video' };
    if (onlyProtected) state = { icon: 'lock', text: 'Protected video' };
    else if (goStatus) state = goStatus;
    go.classList.toggle('tinted', !onlyProtected);
    go.classList.toggle('is-protected', onlyProtected);
    go.disabled = onlyProtected;
    go.title = onlyProtected ? 'This video is copy-protected (DRM), so it cannot be downloaded.' : choice?.title || '';
    // Rebuilt only when it changes, so a click in progress is never disturbed.
    const key = `${state.icon}|${state.text}`;
    if (go.dataset.state === key) return;
    go.dataset.state = key;
    go.innerHTML = `${panelIcons[state.icon]}<span class="go-label"></span>`;
    go.querySelector('.go-label').textContent = state.text;
  }

  function renderPanel() {
    if (dismissedOn === location.href) return;
    const target = largestPlayer();
    const { heading, fallbackKey, options } = panelChoices();
    if (!target || (options.length === 0 && media.length === 0)) return;
    if (target !== panelTarget) {
      if (panelTarget) sizeWatcher?.unobserve(panelTarget);
      panelTarget = target;
      if (panelHost) sizeWatcher?.observe(target);
    }
    if (!panelHost) buildPanel();
    const shadow = panelHost.shadowRoot;
    // The first default (the newest stream so far, or the app's default quality) stays until the person picks another.
    const choice = options.find((option) => option.key === chosenKey) || options.find((option) => option.key === fallbackKey) || options[options.length - 1];
    if (choice) chosenKey = choice.key;
    currentChoice = choice || null;
    renderedHref = location.href;
    const pick = shadow.querySelector('.pick');
    const menu = shadow.querySelector('.menu');
    pick.hidden = options.length < 2;
    pick.title = choice ? `${choice.detail}\n${choice.title}` : '';
    pick.setAttribute('aria-label', choice ? `Choose what to download. Now: ${choice.name}` : 'Choose what to download');
    pick.querySelector('.label').textContent = choice ? choice.short : '';
    // Rebuilt only when the list or the choice changed, so an open menu keeps its scroll, hover and focus.
    const signature = `${choice?.key}|${heading}|${options.map((option) => option.key).join('|')}`;
    if (signature !== menuSignature) {
      menuSignature = signature;
      const head = document.createElement('div');
      head.className = 'menu-head';
      head.textContent = heading;
      // The options scroll inside their own box, so the menu's glass edge stays put while they move.
      const list = document.createElement('div');
      list.className = 'menu-list';
      list.append(...options.map((option) => menuOption(option, option === choice)));
      const scrolled = menu.querySelector('.menu-list')?.scrollTop || 0;
      menu.replaceChildren(head, list);
      list.scrollTop = scrolled;
    }
    if (pick.hidden) setMenuOpen(false);
    renderGo(choice, options.length === 0 && (pageUsesDRM || media.some((item) => item.protected)));
    place();
  }

  // YouTube moves between videos without loading a new page, so its pages are looked at once a second.
  if (/(^|\.)youtube(-nocookie)?\.com$/i.test(location.hostname)) {
    let lastHref = location.href;
    setInterval(async () => {
      const video = youtubeVideo();
      if (location.href !== lastHref) {
        lastHref = location.href;
        youtubeConfig = null;
        if (!video && media.length === 0 && panelHost) removePanel();
      }
      if (!video) return;
      // Asked again on every new page, so a change of the default quality in the app shows up.
      if (!youtubeConfig) youtubeConfig = await chrome.runtime.sendMessage({ type: 'getConfig' }).catch(() => null);
      if (!youtubeConfig?.videoPanelEnabled || siteExcluded(youtubeConfig)) return;
      if (!panelHost || location.href !== renderedHref || largestPlayer() !== panelTarget) renderPanel();
    }, 1000);
  }

  // The frame's visible size without scroll bars (old "quirks mode" pages report it on <body>).
  function frameSize() {
    const root = document.compatMode === 'BackCompat' ? document.body : document.documentElement;
    return { width: root?.clientWidth || innerWidth, height: root?.clientHeight || innerHeight };
  }

  function place() {
    if (!panelHost?.isConnected || !panelTarget) return;
    const panel = panelHost.shadowRoot.querySelector('.panel');
    panelHost.style.display = 'block';
    const frame = frameSize();
    const spot = rules.panelPosition(panelTarget.getBoundingClientRect(), { width: panel.offsetWidth, height: panel.offsetHeight }, frame);
    if (!spot.visible) {
      panelHost.style.display = 'none';
      return;
    }
    panel.style.left = `${spot.left}px`;
    panel.style.top = `${spot.top}px`;
    placeMenu(frame);
  }

  function placeMenu(frame = frameSize()) {
    const shadow = panelHost.shadowRoot;
    const menu = shadow.querySelector('.menu');
    if (menu.hidden) return;
    const options = menu.querySelector('.menu-list');
    const scrolled = options ? options.scrollTop : 0;
    menu.style.maxHeight = 'none';
    const spot = rules.menuPlacement(shadow.querySelector('.panel').getBoundingClientRect(), { width: menu.offsetWidth, height: menu.offsetHeight }, frame);
    menu.style.maxHeight = `${spot.maxHeight}px`;
    menu.style.left = `${spot.left}px`;
    menu.style.top = `${spot.top}px`;
    if (options) options.scrollTop = scrolled;
  }
})();
