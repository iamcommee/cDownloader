// Runs inside the page itself. It only reports that the page asked for DRM keys,
// so the add-on can label such videos as protected instead of offering a download.
(() => {
  if (window.__cDownloaderHooks || !navigator.requestMediaKeySystemAccess) return;
  window.__cDownloaderHooks = true;
  const original = navigator.requestMediaKeySystemAccess.bind(navigator);
  navigator.requestMediaKeySystemAccess = function (...args) {
    window.postMessage({ source: 'cdownloader-page', type: 'drm' }, '*');
    return original(...args);
  };
})();
