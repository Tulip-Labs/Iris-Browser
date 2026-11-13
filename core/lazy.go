package core

// LazyScript makes a page load only what the reader is near: pictures and
// frames further down wait until scrolling brings them close (the engine's
// own lazy loading, switched on for elements that did not ask for it), and
// videos that do not play by themselves fetch only their first details.
// What the engine has already started fetching is not stopped, so the saving
// is largest on long pages that add their content as they go.
const LazyScript = `(() => {
  if (window.__liteLazy) return;
  window.__liteLazy = true;
  const fix = (el) => {
    const tag = el.tagName;
    if (tag === 'IMG' || tag === 'IFRAME') {
      if (!el.hasAttribute('loading')) el.setAttribute('loading', 'lazy');
      if (tag === 'IMG' && !el.hasAttribute('decoding')) el.setAttribute('decoding', 'async');
    } else if (tag === 'VIDEO' || tag === 'AUDIO') {
      if (!el.autoplay && !el.hasAttribute('preload')) el.setAttribute('preload', 'metadata');
    }
  };
  const walk = (node) => {
    if (node.nodeType !== 1) return;
    fix(node);
    if (node.firstElementChild) node.querySelectorAll('img,iframe,video,audio').forEach(fix);
  };
  try {
    new MutationObserver((list) => {
      for (const m of list) for (const n of m.addedNodes) walk(n);
    }).observe(document, { childList: true, subtree: true });
  } catch (e) {}
})();`
