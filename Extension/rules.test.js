import { test } from 'node:test';
import assert from 'node:assert/strict';
import { wildcardMatch, shouldIntercept, isMediaResponse, extensionOf, displayName, formatSize, describeMedia, panelPosition, menuPlacement, youtubeLink, videoQualities, qualityLabel } from './rules.js';

const base = { integrationEnabled: true, extensions: ['zip', 'pdf', 'r0*'], dontCaptureSites: [], addressExceptions: [] };

// T14-01
const interceptRows = [
  ['base', { url: 'https://h.example/a.zip' }, {}, true],
  ['integration off', { url: 'https://h.example/a.zip' }, { integrationEnabled: false }, false],
  ['not listed', { url: 'https://h.example/a.html' }, {}, false],
  ['case', { url: 'https://h.example/A.ZIP' }, {}, true],
  ['filename wins over url', { url: 'https://h.example/get?id=4', filename: '/Users/x/Downloads/report.pdf' }, {}, true],
  ['wildcard type', { url: 'https://h.example/part.r01' }, {}, true],
  ['site excluded', { url: 'https://cdn.foo.com/a.zip' }, { dontCaptureSites: ['*.foo.com'] }, false],
  ['address exception', { url: 'https://h.example/private/a.zip' }, { addressExceptions: ['*/private/*'] }, false],
  ['skip key held', { url: 'https://h.example/a.zip', skipKey: true }, {}, false],
  ['force key held', { url: 'https://h.example/a.html', forceKey: true }, {}, true],
  ['force with integration off', { url: 'https://h.example/a.zip', forceKey: true }, { integrationEnabled: false }, false],
  ['force beats site exclusion', { url: 'https://cdn.foo.com/a.html', forceKey: true }, { dontCaptureSites: ['*.foo.com'] }, true],
  ['blob', { url: 'blob:https://h.example/123' }, {}, false],
  ['data with force', { url: 'data:application/zip;base64,AAAA', forceKey: true }, {}, false],
  ['query', { url: 'https://h.example/a.zip?x=1' }, {}, true],
  ['mime fallback', { url: 'https://h.example/download?id=5', mime: 'application/zip' }, {}, true],
  ['stream playlist link', { url: 'https://h.example/live/master.m3u8' }, { extensions: ['zip', 'm3u8'] }, true],
  ['stream playlist by type', { url: 'https://h.example/play?id=9', mime: 'application/vnd.apple.mpegurl' }, { extensions: ['m3u8'] }, true],
  ['stream playlist by type 2', { url: 'https://h.example/play?id=9', mime: 'application/x-mpegURL' }, { extensions: ['m3u8'] }, true],
];

for (const [label, download, change, expected] of interceptRows) {
  test(`T14-01 shouldIntercept: ${label}`, () => {
    assert.equal(shouldIntercept(download, { ...base, ...change }), expected);
  });
}

// T14-02
const big = String(5 * 1024 * 1024);
const mediaRows = [
  ['video', { url: 'https://v.example/clip.mp4', headers: { 'Content-Type': 'video/mp4', 'Content-Length': big } }, { media: true, kind: 'video', protected: false }],
  ['audio', { url: 'https://v.example/song', headers: [{ name: 'content-type', value: 'audio/mpeg' }, { name: 'content-length', value: big }] }, { media: true, kind: 'audio', protected: false }],
  ['hls mime', { url: 'https://v.example/x', headers: { 'content-type': 'application/vnd.apple.mpegurl' } }, { media: true, kind: 'hls', protected: false }],
  ['hls mime 2', { url: 'https://v.example/x', headers: { 'content-type': 'application/x-mpegURL' } }, { media: true, kind: 'hls', protected: false }],
  ['m3u8 url', { url: 'https://v.example/master.m3u8?token=1', headers: { 'content-type': 'application/octet-stream' } }, { media: true, kind: 'hls', protected: false }],
  ['dash', { url: 'https://v.example/manifest.mpd', headers: { 'content-type': 'application/dash+xml' } }, { media: true, kind: 'dash', protected: false }],
  ['tiny', { url: 'https://v.example/clip.mp4', headers: { 'content-type': 'video/mp4', 'content-length': '1000' } }, { media: false, kind: null, protected: false }],
  ['beacon', { url: 'https://ads.doubleclick.net/pagead/video.mp4', headers: { 'content-type': 'video/mp4', 'content-length': big } }, { media: false, kind: null, protected: false }],
  ['drm', { url: 'https://v.example/movie.ism/manifest', headers: { 'content-type': 'application/vnd.ms-sstr+xml' } }, { media: true, kind: 'dash', protected: true }],
  ['html', { url: 'https://v.example/page', headers: { 'content-type': 'text/html' } }, { media: false, kind: null, protected: false }],
  ['missing headers', { url: 'https://v.example/x' }, { media: false, kind: null, protected: false }],
  ['undefined input', undefined, { media: false, kind: null, protected: false }],
  // T17-14: YouTube's own picture and sound pieces are not videos on their own.
  ['youtube piece', { url: 'https://rr1---sn-xyz.googlevideo.com/videoplayback?expire=1&itag=137', headers: { 'content-type': 'video/mp4', 'content-length': big } }, { media: false, kind: null, protected: false }],
  ['youtube piece, bare host', { url: 'https://googlevideo.com/videoplayback?itag=140', headers: { 'content-type': 'audio/mp4', 'content-length': big } }, { media: false, kind: null, protected: false }],
  ['look-alike host (guard)', { url: 'https://evilgooglevideo.com/videoplayback', headers: { 'content-type': 'video/mp4', 'content-length': big } }, { media: true, kind: 'video', protected: false }],
  ['look-alike suffix (guard)', { url: 'https://googlevideo.com.evil.example/videoplayback', headers: { 'content-type': 'video/mp4', 'content-length': big } }, { media: true, kind: 'video', protected: false }],
  ['other googlevideo path (guard)', { url: 'https://r1.googlevideo.com/other.mp4', headers: { 'content-type': 'video/mp4', 'content-length': big } }, { media: true, kind: 'video', protected: false }],
];

for (const [label, response, expected] of mediaRows) {
  test(`T14-02 isMediaResponse: ${label}`, () => {
    assert.deepEqual(isMediaResponse(response, { minimumBytes: 300 * 1024 }), expected);
  });
}

test('T14-02 minimum size is configurable', () => {
  const response = { url: 'https://v.example/a.mp4', headers: { 'content-type': 'video/mp4', 'content-length': '2000' } };
  assert.equal(isMediaResponse(response, { minimumBytes: 1000 }).media, true);
});

// T14-03 mirrors Swift T3-03
const wildcardRows = [
  ['mid', '*.example.com', 'cdn.EXAMPLE.com', true],
  ['none', '*.example.com', 'example.org', false],
  ['literal dot', 'a.c', 'abc', false],
  ['all', '*', 'anything', true],
  ['empty text', '*', '', true],
  ['regex chars', 'a+b(*)', 'a+b(x)', true],
  ['star middle', 'img*.jpg', 'img042.jpg', true],
  ['empty pattern', '', 'x', false],
];

for (const [label, pattern, text, expected] of wildcardRows) {
  test(`T14-03 wildcard: ${label}`, () => {
    assert.equal(wildcardMatch(pattern, text), expected);
  });
}

test('extensionOf reads names and URLs', () => {
  assert.equal(extensionOf('https://h.example/dir/File.TAR.GZ?x=1#y'), 'gz');
  assert.equal(extensionOf('/Users/x/Downloads/a.pdf'), 'pdf');
  assert.equal(extensionOf('https://h.example/'), '');
  assert.equal(extensionOf(undefined), '');
});

// T16-01: sizes read like "2.3 MB"; unknown sizes are left out. The unit is picked after rounding.
const MB = 1048576;
const sizeRows = [
  ['undefined', undefined, ''],
  ['null', null, ''],
  ['zero', 0, ''],
  ['negative', -5, ''],
  ['NaN', NaN, ''],
  ['Infinity', Infinity, ''],
  ['numeric string', '12', ''],
  ['1 byte', 1, '1 B'],
  ['under 1 KB', 512, '512 B'],
  ['max bytes', 1023, '1023 B'],
  ['exactly 1 KB', 1024, '1 KB'],
  ['KB no decimals', 300 * 1024, '300 KB'],
  ['KB rounding', 1536, '2 KB'],
  ['just under 1 MB', MB - 1, '1.0 MB'],
  ['exactly 1 MB', MB, '1.0 MB'],
  ['MB decimal', 2.3 * MB, '2.3 MB'],
  ['just under 1 GB', 1024 * MB - 1, '1.0 GB'],
  ['GB', 1024 * MB, '1.0 GB'],
  ['GB decimal', 2.5 * 1024 * MB, '2.5 GB'],
  ['old output kept (guard)', 5 * MB, '5.0 MB'],
];

for (const [label, input, expected] of sizeRows) {
  test(`T16-01 formatSize: ${label}`, () => {
    assert.equal(formatSize(input), expected);
  });
}

// T16-02: label parts per media kind. A stream's size is its playlist's size, so it is never shown.
const longUrl = `https://v.example/${'very-long-video-name-'.repeat(5)}.mp4`;
const mediaLabelRows = [
  ['video mp4', [{ url: 'https://v.example/clip.mp4', kind: 'video', size: 2.3 * MB }], { kind: 'Video', format: 'MP4', size: '2.3 MB', name: 'clip.mp4' }],
  ['audio mp3', [{ url: 'https://v.example/a.mp3', kind: 'audio', size: 300 * 1024 }], { kind: 'Audio', format: 'MP3', size: '300 KB', name: 'a.mp3' }],
  ['hls', [{ url: 'https://v.example/master.m3u8', kind: 'hls', size: 4096 }], { kind: 'Stream', format: 'HLS', size: '', name: 'master.m3u8' }],
  ['dash', [{ url: 'https://v.example/m.mpd', kind: 'dash', size: 4096 }], { kind: 'Stream', format: 'DASH', size: '', name: 'm.mpd' }],
  ['hls without size', [{ url: 'https://v.example/master.m3u8', kind: 'hls' }], { kind: 'Stream', format: 'HLS', size: '', name: 'master.m3u8' }],
  ['video without size', [{ url: 'https://v.example/clip.mp4', kind: 'video' }], { kind: 'Video', format: 'MP4', size: '', name: 'clip.mp4' }],
  ['no extension', [{ url: 'https://v.example/play?id=9', kind: 'video' }], { kind: 'Video', format: '', size: '', name: 'play' }],
  ['query on extension', [{ url: 'https://v.example/clip.webm?t=1', kind: 'video' }], { kind: 'Video', format: 'WEBM', size: '', name: 'clip.webm' }],
  ['unknown kind', [{ url: 'https://v.example/x.mp4', kind: 'weird' }], { kind: 'Media', format: 'MP4', size: '', name: 'x.mp4' }],
  ['missing kind', [{ url: 'https://v.example/x.mp4' }], { kind: 'Media', format: 'MP4', size: '', name: 'x.mp4' }],
  ['empty item', [{}], { kind: 'Media', format: '', size: '', name: '' }],
  ['undefined item', [undefined], { kind: 'Media', format: '', size: '', name: '' }],
];

for (const [label, args, expected] of mediaLabelRows) {
  test(`T16-02 describeMedia: ${label}`, () => {
    assert.deepEqual(describeMedia(...args), expected);
  });
}

test('T16-02 describeMedia: two streams get different names, and max is honored', () => {
  const first = describeMedia({ url: 'https://v.example/a/720p.m3u8', kind: 'hls' });
  const second = describeMedia({ url: 'https://v.example/a/1080p.m3u8', kind: 'hls' });
  assert.notEqual(first.name, second.name);
  const short = describeMedia({ url: longUrl, kind: 'video' }, 10);
  assert.ok(short.name.length <= 10);
  assert.equal(short.name, displayName(longUrl, 10));
});

// T16-03: the panel sits at the player's top-right corner and always stays inside the frame it is drawn in.
const vp = { width: 1000, height: 800 };
const panel = { width: 500, height: 60 };
const player = (change) => ({ top: 100, right: 700, bottom: 400, left: 100, width: 600, height: 300, ...change });
const placeRows = [
  ['player inside', player(), panel, vp, undefined, { visible: true, left: 192, top: 108 }],
  ['right edge at viewport', player({ right: 1000, left: 400 }), panel, vp, undefined, { visible: true, left: 492, top: 108 }],
  ['right edge past viewport (iframe cut)', player({ right: 1400, left: 200, width: 1200 }), panel, vp, undefined, { visible: true, left: 492, top: 108 }],
  ['very wide player', player({ right: 5000, left: 0, width: 5000 }), panel, vp, undefined, { visible: true, left: 492, top: 108 }],
  ['left clamp', player({ right: 300, left: 0, width: 300 }), panel, vp, undefined, { visible: true, left: 8, top: 108 }],
  ['panel wider than viewport', player({ right: 1000 }), { width: 1200, height: 60 }, vp, undefined, { visible: true, left: 8, top: 108 }],
  ['panel fills viewport minus margins', player({ right: 1000 }), { width: 984, height: 60 }, vp, undefined, { visible: true, left: 8, top: 108 }],
  ['player top above viewport', player({ top: -200, bottom: 300 }), panel, vp, undefined, { visible: true, left: 192, top: 8 }],
  ['player top inside', player({ top: 50 }), panel, vp, undefined, { visible: true, left: 192, top: 58 }],
  ['top clamp near bottom', player({ top: 790, bottom: 1200 }), panel, vp, undefined, { visible: true, left: 192, top: 732 }],
  ['panel taller than viewport', player(), { width: 500, height: 900 }, vp, undefined, { visible: true, left: 192, top: 8 }],
  ['small iframe, player wider than frame', { top: 0, right: 600, bottom: 340, left: 0, width: 600, height: 340 }, { width: 330, height: 40 }, { width: 400, height: 300 }, undefined, { visible: true, left: 62, top: 8 }],
  ['custom gap', player({ right: 1000 }), panel, vp, 20, { visible: true, left: 480, top: 120 }],
  ['bottom just inside (guard)', player({ top: -299, bottom: 1 }), panel, vp, undefined, { visible: true }],
  ['top just inside', player({ top: 799, bottom: 1099 }), panel, vp, undefined, { visible: true }],
  ['fully above', player({ top: -300, bottom: 0 }), panel, vp, undefined, { visible: false }],
  ['fully below', player({ top: 800, bottom: 1100 }), panel, vp, undefined, { visible: false }],
  ['zero width', player({ width: 0, right: 100 }), panel, vp, undefined, { visible: false }],
];

for (const [label, target, size, viewport, gap, expected] of placeRows) {
  test(`T16-03 panelPosition: ${label}`, () => {
    const result = panelPosition(target, size, viewport, gap);
    const margin = gap ?? 8;
    assert.equal(result.visible, expected.visible);
    if ('left' in expected) assert.equal(result.left, expected.left);
    if ('top' in expected) assert.equal(result.top, expected.top);
    if (result.visible) {
      assert.ok(result.left >= margin && result.top >= margin);
      assert.ok(result.left + size.width <= Math.max(viewport.width - margin, margin + size.width));
    }
  });
}

// T16-04: the media menu opens on the side with room, has a bounded height, and stays inside the frame.
// Default anchor is the panel at right 800; a short frame clamps the menu's top instead of letting it leave the frame.
const anchor = (top, bottom, change) => ({ top, bottom, left: 600, right: 800, ...change });
const menuRows = [
  ['plenty below, capped', anchor(100, 160), { width: 200, height: 200 }, undefined, { up: false, maxHeight: 320, left: 600, top: 168 }],
  ['fits below exactly', anchor(100, 576), { width: 200, height: 208 }, undefined, { up: false, maxHeight: 208, left: 600, top: 584 }],
  ['one px short, below >= above', anchor(100, 577), { width: 200, height: 208 }, undefined, { up: false, maxHeight: 207, left: 600, top: 585 }],
  ['no fit, above larger, capped', anchor(500, 560), { width: 200, height: 400 }, undefined, { up: true, maxHeight: 320, left: 600, top: 172 }],
  ['up with modest room', anchor(216, 684), { width: 200, height: 400 }, undefined, { up: true, maxHeight: 200, left: 600, top: 8 }],
  ['tie, not fitting, goes below', anchor(300, 500), { width: 200, height: 400 }, undefined, { up: false, maxHeight: 284, left: 600, top: 508 }],
  ['up, menu shorter than max', anchor(500, 700), { width: 200, height: 150 }, undefined, { up: true, maxHeight: 320, left: 600, top: 342 }],
  ['floor below, top clamped into frame', anchor(26, 754), { width: 200, height: 400 }, undefined, { up: false, maxHeight: 120, left: 600, top: 672 }],
  ['floor up, top clamped into frame', anchor(66, 764), { width: 200, height: 400 }, undefined, { up: true, maxHeight: 120, left: 600, top: 8 }],
  ['right-aligned, normal', anchor(100, 160), { width: 200, height: 100 }, undefined, { up: false, maxHeight: 320, left: 600, top: 168 }],
  ['menu edge exactly at the limit', anchor(100, 160, { right: 992 }), { width: 200, height: 100 }, undefined, { up: false, maxHeight: 320, left: 792, top: 168 }],
  ['anchor right past viewport (iframe cut)', anchor(100, 160, { right: 1400 }), { width: 200, height: 100 }, undefined, { up: false, maxHeight: 320, left: 792, top: 168 }],
  ['narrow panel near left edge', anchor(100, 160, { left: 8, right: 120 }), { width: 300, height: 100 }, undefined, { up: false, maxHeight: 320, left: 8, top: 168 }],
  ['menu fills the width exactly', anchor(100, 160, { right: 1000 }), { width: 984, height: 100 }, undefined, { up: false, maxHeight: 320, left: 8, top: 168 }],
  ['menu wider than viewport', anchor(100, 160, { right: 1000 }), { width: 1200, height: 100 }, undefined, { up: false, maxHeight: 320, left: 8, top: 168 }],
  ['custom gap', anchor(100, 160, { right: 100 }), { width: 200, height: 100 }, 20, { up: false, maxHeight: 320, left: 20, top: 180 }],
];

for (const [label, box, menu, gap, expected] of menuRows) {
  test(`T16-04 menuPlacement: ${label}`, () => {
    const result = menuPlacement(box, menu, vp, gap);
    const margin = gap ?? 8;
    assert.deepEqual(result, expected);
    assert.ok(result.left >= margin);
    assert.ok(result.left + menu.width <= Math.max(vp.width - margin, margin + menu.width));
  });
}

test('T16-04 menuPlacement: missing or zero menu size never throws', () => {
  for (const menu of [{ width: 200 }, { width: 200, height: 0 }, undefined]) {
    const result = menuPlacement(anchor(100, 160), menu, vp);
    assert.equal(result.up, false);
    assert.ok(Number.isFinite(result.left) && Number.isFinite(result.top));
  }
});

// CR-02: a player scrolled out sideways (a carousel, or a frame cut on one side) hides the panel instead of pinning it to the edge.
const sidewaysRows = [
  ['player fully right of the frame', { left: 900, right: 1300, top: 50, bottom: 300, width: 400, height: 250 }, false],
  ['player fully left of the frame', { left: -500, right: -100, top: 50, bottom: 300, width: 400, height: 250 }, false],
  ['right edge exactly at the frame start', { left: -400, right: 0, top: 50, bottom: 300, width: 400, height: 250 }, false],
  ['left edge exactly at the frame end', { left: 600, right: 1000, top: 50, bottom: 300, width: 400, height: 250 }, false],
  ['one pixel inside on the right (guard)', { left: 599, right: 999, top: 50, bottom: 300, width: 400, height: 250 }, true],
  ['one pixel inside on the left (guard)', { left: -399, right: 1, top: 50, bottom: 300, width: 400, height: 250 }, true],
];

for (const [label, target, expected] of sidewaysRows) {
  test(`CR-02 panelPosition: ${label}`, () => {
    assert.equal(panelPosition(target, { width: 450, height: 40 }, { width: 600, height: 400 }).visible, expected);
  });
}

// T17-13: the add-on recognizes the same YouTube addresses as the app (same rows as Swift T17-01).
const ytId = 'dQw4w9WgXcQ';
const ytList = 'PLabc_12-x';
const ytVideo = (id = ytId) => ({ type: 'video', id, url: `https://www.youtube.com/watch?v=${id}` });
const ytPlaylist = (id = ytList) => ({ type: 'playlist', id, url: `https://www.youtube.com/playlist?list=${id}` });
const youtubeRows = [
  ['watch', `https://www.youtube.com/watch?v=${ytId}`, ytVideo()],
  ['watch with list', `https://www.youtube.com/watch?v=${ytId}&list=${ytList}`, ytVideo()],
  ['v not first', `https://www.youtube.com/watch?feature=share&v=${ytId}`, ytVideo()],
  ['no www', `https://youtube.com/watch?v=${ytId}`, ytVideo()],
  ['mobile', `https://m.youtube.com/watch?v=${ytId}`, ytVideo()],
  ['music', `https://music.youtube.com/watch?v=${ytId}`, ytVideo()],
  ['nocookie embed', `https://www.youtube-nocookie.com/embed/${ytId}`, ytVideo()],
  ['nocookie without www', `https://youtube-nocookie.com/embed/${ytId}`, ytVideo()],
  ['youtu.be', `https://youtu.be/${ytId}?t=10`, ytVideo()],
  ['shorts', `https://www.youtube.com/shorts/${ytId}`, ytVideo()],
  ['live', `https://www.youtube.com/live/${ytId}`, ytVideo()],
  ['embed', `https://www.youtube.com/embed/${ytId}`, ytVideo()],
  ['old v path', `https://www.youtube.com/v/${ytId}`, ytVideo()],
  ['uppercase host', `HTTPS://WWW.YouTube.COM/watch?v=${ytId}`, ytVideo()],
  ['http scheme', `http://youtu.be/${ytId}`, ytVideo()],
  ['playlist', `https://www.youtube.com/playlist?list=${ytList}`, ytPlaylist()],
  ['embedded playlist', `https://www.youtube.com/embed/videoseries?list=${ytList}`, ytPlaylist()],
  ['playlist id of 2', 'https://www.youtube.com/playlist?list=PL', ytPlaylist('PL')],
  ['playlist id of 1', 'https://www.youtube.com/playlist?list=P', null],
  ['playlist without list', 'https://www.youtube.com/playlist', null],
  ['id of 10', 'https://www.youtube.com/watch?v=abcdefghij', null],
  ['id of 12', 'https://www.youtube.com/watch?v=abcdefghijkl', null],
  ['id with bad char', 'https://www.youtube.com/watch?v=abc!defghij', null],
  ['watch without v', 'https://www.youtube.com/watch', null],
  ['channel', 'https://www.youtube.com/@name', null],
  ['home', 'https://www.youtube.com/', null],
  ['search', 'https://www.youtube.com/results?search_query=x', null],
  ['channel id', 'https://www.youtube.com/channel/UC1', null],
  ['look-alike prefix', `https://notyoutube.com/watch?v=${ytId}`, null],
  ['look-alike suffix', `https://youtube.com.evil.example/watch?v=${ytId}`, null],
  ['look-alike short', `https://evilyoutu.be/${ytId}`, null],
  ['look-alike short suffix', `https://youtu.be.evil.com/${ytId}`, null],
  ['ftp scheme', `ftp://youtube.com/watch?v=${ytId}`, null],
  ['file scheme', 'file:///x', null],
  ['no scheme', `youtube.com/watch?v=${ytId}`, null],
];

for (const [label, url, expected] of youtubeRows) {
  test(`T17-13 youtubeLink: ${label}`, () => {
    assert.deepEqual(youtubeLink(url), expected);
  });
}

test('T17-13 youtubeLink: junk input never throws', () => {
  for (const input of [undefined, null, 42, {}, '', 'not a url', 'javascript:alert(1)']) {
    assert.doesNotThrow(() => youtubeLink(input));
    assert.equal(youtubeLink(input), null);
  }
});

// T17-15: the qualities offered match the app's (Swift VideoQuality raw values).
test('T17-15 videoQualities and qualityLabel', () => {
  assert.deepEqual(videoQualities.map((quality) => quality.value), ['best', '1080', '720', '480', '360', 'audio']);
  for (const quality of videoQualities) {
    assert.ok(quality.label && quality.detail);
    assert.equal(qualityLabel(quality.value), quality.label);
  }
  assert.equal(qualityLabel('4k'), videoQualities[0].label);
  assert.doesNotThrow(() => qualityLabel(undefined));
  assert.equal(qualityLabel(undefined), videoQualities[0].label);
});
