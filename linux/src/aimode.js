// Iris's Liquid Glass for Google AI Mode (only there): the dawn behind the
// page, its large white panels made clear so the dawn shows, and the
// question box made of glass. Nothing else on Google, and no other site.
(() => {
  if (window.top !== window || window.__irisAI) return;
  window.__irisAI = true;
  const css = `
html.iris-ai { background: linear-gradient(160deg, #aebcff 0%, #d4c4ff 28%, #ffcfe6 58%, #ffe1cf 84%, #fff1df 100%) fixed !important; min-height: 100%; }
html.iris-ai body { background: transparent !important; }
html.iris-ai body::before { content: ''; position: fixed; inset: 0; pointer-events: none; z-index: -1;
  background: radial-gradient(60vmax 40vmax at 82% 0%, rgba(255, 122, 200, .26), transparent 70%),
              radial-gradient(60vmax 50vmax at 0% 100%, rgba(95, 184, 255, .28), transparent 70%),
              radial-gradient(42vmax 32vmax at 74% 34%, rgba(255, 253, 245, .75), transparent 70%); }
html.iris-ai .iris-clear { background-color: transparent !important; box-shadow: none !important; }
html.iris-ai .iris-glass { background: rgba(255, 255, 255, .55) !important;
  -webkit-backdrop-filter: blur(24px) saturate(180%); backdrop-filter: blur(24px) saturate(180%);
  border: 1px solid rgba(255, 255, 255, .9) !important; border-radius: 28px !important;
  box-shadow: 0 12px 36px rgba(90, 63, 192, .18), inset 0 1px 0 rgba(255, 255, 255, .95), inset 0 -1px 0 rgba(90, 63, 192, .08) !important; }
html.iris-ai ::selection { background: rgba(106, 76, 245, .22); }`;
  const root = document.documentElement;
  const isAI = () => {
    const u = new URL(location.href);
    return u.pathname === '/aimode' || (u.pathname === '/search' && u.searchParams.get('udm') === '50');
  };
  const style = () => {
    if (document.getElementById('iris-ai-style')) return;
    const s = document.createElement('style');
    s.id = 'iris-ai-style';
    s.textContent = css;
    (document.head || root).appendChild(s);
  };
  const white = /^rgba?\(255, 255, 255(, 1)?\)$/;
  const seen = new WeakSet();
  let pending = false;
  const tidy = () => {
    pending = false;
    const on = isAI();
    root.classList.toggle('iris-ai', on);
    if (!on) return;
    style();
    if (!document.body) return;
    const wide = innerWidth * 0.5;
    for (const el of document.body.querySelectorAll('div, header, footer, main, form, section')) {
      if (seen.has(el)) continue;
      seen.add(el);
      if (el.offsetWidth > wide && white.test(getComputedStyle(el).backgroundColor)) el.classList.add('iris-clear');
    }
    for (const ta of document.querySelectorAll('textarea')) {
      let el = ta.parentElement;
      for (let n = 0; el && n < 6; n++, el = el.parentElement) {
        if ((parseFloat(getComputedStyle(el).borderTopLeftRadius) || 0) >= 12 && el.offsetWidth > 200) {
          el.classList.add('iris-glass');
          el.classList.remove('iris-clear');
          break;
        }
      }
    }
  };
  const later = () => { if (!pending) { pending = true; setTimeout(tidy, 120); } };
  new MutationObserver(later).observe(root, { childList: true, subtree: true });
  addEventListener('popstate', later);
  addEventListener('load', later);
  later();
})();
