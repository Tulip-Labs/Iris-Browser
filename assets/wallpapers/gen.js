// Ember's wallpapers: Iris, goddess of the rainbow, in liquid glass.
// node gen.js -> iris-light.svg, iris-dark.svg
const fs = require('fs');
const icon = fs.readFileSync(process.argv[2], 'utf8');
const pick = id => icon.match(new RegExp(`<path id="${id}" d="([^"]+)"`))[1];
const head = pick('head'), wing = pick('wing');
const hair = icon.match(/<!-- the hair[\s\S]*?<\/g>/)[0];
const face = icon.match(/<!-- brow, eye and lips[\s\S]*?(?=\n    <\/g>)/)[0];
const glints = icon.match(/<!-- glints[\s\S]*?<\/g>/)[0];

function rng(seed) { return () => (seed = (seed * 16807) % 2147483647) / 2147483647; }

function svg(dark, P) {
  P = P || {W:1920,H:1080,T:'translate(950 96) scale(1.08)',arc:'${P.arc}',wl:[1310,650],hl:[1510,640,660],ow:900,oh:860,sh:760,fade:[0.66,0.93]};
  const T = P.T;
  const sky = dark
    ? [['0', '#07051a'], ['0.45', '#16104a'], ['0.8', '#1d1a6b'], ['1', '#052a46']]
    : [['0', '#fbf6f1'], ['0.4', '#f4e9f7'], ['0.75', '#e4ecff'], ['1', '#d9f1fb']];
  const glowA = dark ? ['#ff5fc8', 0.30] : ['#ffb3dc', 0.55];
  const glowB = dark ? ['#2fb4ff', 0.26] : ['#9fdcff', 0.55];
  const bowOp = dark ? 0.95 : 0.62;
  const stars = [];
  if (dark) {
    const r = rng(7);
    for (let i = 0; i < 220; i++) {
      const x = r() * P.W, y = r() * P.sh, s = r() * 1.3 + 0.3, o = (r() * 0.6 + 0.25).toFixed(2);
      stars.push(`<circle cx="${x.toFixed(1)}" cy="${y.toFixed(1)}" r="${s.toFixed(2)}" fill="#fff" opacity="${o}"/>`);
    }
  }
  const orbs = [];
  {
    const r = rng(dark ? 11 : 5);
    for (let i = 0; i < 9; i++) {
      const x = 80 + r() * P.ow, y = 120 + r() * P.oh, s = 10 + r() * 34;
      orbs.push(`<g opacity="${dark ? 0.55 : 0.75}"><circle cx="${x.toFixed(0)}" cy="${y.toFixed(0)}" r="${s.toFixed(0)}" fill="url(#orb)"/><circle cx="${x.toFixed(0)}" cy="${y.toFixed(0)}" r="${s.toFixed(0)}" fill="none" stroke="url(#rim)" stroke-width="1.6"/></g>`);
    }
  }
  const tint = dark ? '#1b0f4a' : '#8c7bd6';
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${P.W} ${P.H}" width="${P.W*2}" height="${P.H*2}">
  <!-- Iris, goddess of the rainbow, in liquid glass: Ember's ${dark ? 'dark' : 'light'} wallpaper.
       An original drawing made for Ember (Tulip Labs), GPL-3.0 like Ember. -->
  <defs>
    <linearGradient id="sky" x1="0" y1="0" x2="0.9" y2="1">${sky.map(([o, c]) => `<stop offset="${o}" stop-color="${c}"/>`).join('')}</linearGradient>
    <radialGradient id="glowA" cx="0.72" cy="0.18" r="0.6"><stop offset="0" stop-color="${glowA[0]}" stop-opacity="${glowA[1]}"/><stop offset="1" stop-color="${glowA[0]}" stop-opacity="0"/></radialGradient>
    <radialGradient id="glowB" cx="0.12" cy="0.95" r="0.7"><stop offset="0" stop-color="${glowB[0]}" stop-opacity="${glowB[1]}"/><stop offset="1" stop-color="${glowB[0]}" stop-opacity="0"/></radialGradient>
    <linearGradient id="bow" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0" stop-color="#ff3b6b"/><stop offset="0.18" stop-color="#ff9f0a"/><stop offset="0.36" stop-color="#ffe14d"/>
      <stop offset="0.54" stop-color="#34d399"/><stop offset="0.7" stop-color="#38bdf8"/><stop offset="0.86" stop-color="#6366f1"/><stop offset="1" stop-color="#d08cff"/>
    </linearGradient>
    <filter id="soft" x="-60%" y="-60%" width="220%" height="220%"><feGaussianBlur stdDeviation="34"/></filter>
    <filter id="haze" x="-60%" y="-60%" width="220%" height="220%"><feGaussianBlur stdDeviation="90"/></filter>
    <filter id="lensblur"><feGaussianBlur stdDeviation="3"/></filter>
    <linearGradient id="glassFill" x1="0.2" y1="0.05" x2="0.8" y2="1">
      <stop offset="0" stop-color="#fff" stop-opacity="${dark ? 0.40 : 0.62}"/><stop offset="0.42" stop-color="#fff" stop-opacity="${dark ? 0.06 : 0.14}"/>
      <stop offset="0.8" stop-color="#fff" stop-opacity="${dark ? 0.10 : 0.2}"/><stop offset="1" stop-color="#fff" stop-opacity="${dark ? 0.30 : 0.5}"/>
    </linearGradient>
    <linearGradient id="rim" x1="0.1" y1="0" x2="0.9" y2="1">
      <stop offset="0" stop-color="#fff" stop-opacity="1"/><stop offset="0.35" stop-color="#fff" stop-opacity="0.3"/>
      <stop offset="0.65" stop-color="#fff" stop-opacity="0.12"/><stop offset="1" stop-color="#fff" stop-opacity="0.9"/>
    </linearGradient>
    <radialGradient id="orb" cx="0.35" cy="0.3" r="0.8"><stop offset="0" stop-color="#fff" stop-opacity="0.55"/><stop offset="0.6" stop-color="#fff" stop-opacity="0.08"/><stop offset="1" stop-color="#fff" stop-opacity="0.22"/></radialGradient>
    <filter id="inner" x="-10%" y="-10%" width="120%" height="120%">
      <feGaussianBlur in="SourceAlpha" stdDeviation="16" result="b"/><feOffset dx="-12" dy="16" result="o"/>
      <feComposite in="SourceAlpha" in2="o" operator="out" result="edge"/><feFlood flood-color="#fff" flood-opacity="0.9"/><feComposite in2="edge" operator="in"/>
    </filter>
    <filter id="innerDark" x="-10%" y="-10%" width="120%" height="120%">
      <feGaussianBlur in="SourceAlpha" stdDeviation="14" result="b"/><feOffset dx="14" dy="-14" result="o"/>
      <feComposite in="SourceAlpha" in2="o" operator="out" result="edge"/><feFlood flood-color="${tint}" flood-opacity="0.35"/><feComposite in2="edge" operator="in"/>
    </filter>
    <filter id="shade" x="-20%" y="-20%" width="140%" height="140%">
      <feGaussianBlur in="SourceAlpha" stdDeviation="22"/><feOffset dx="14" dy="28"/>
      <feComponentTransfer><feFuncA type="linear" slope="${dark ? 0.55 : 0.22}"/></feComponentTransfer>
    </filter>
    <linearGradient id="fadeDown" x1="0" y1="0" x2="0" y2="1">
      <stop offset="${P.fade[0]}" stop-color="#fff"/><stop offset="${P.fade[1]}" stop-color="#fff" stop-opacity="0"/>
    </linearGradient>
    <mask id="neck" maskUnits="userSpaceOnUse" x="0" y="0" width="${P.W}" height="${P.H}"><rect width="${P.W}" height="${P.H}" fill="url(#fadeDown)"/></mask>
    <path id="head" d="${head}"/>
    <path id="wing" d="${wing}"/>
    <g id="scene">
      <rect width="${P.W}" height="${P.H}" fill="url(#sky)"/>
      <rect width="${P.W}" height="${P.H}" fill="url(#glowA)"/>
      <rect width="${P.W}" height="${P.H}" fill="url(#glowB)"/>
      <path d="${P.arc}" fill="none" stroke="url(#bow)" stroke-width="420" filter="url(#haze)" opacity="${dark ? 0.55 : 0.4}"/>
      <path d="${P.arc}" fill="none" stroke="url(#bow)" stroke-width="150" filter="url(#soft)" opacity="${bowOp}"/>
      <path d="${P.arc}" fill="none" stroke="url(#bow)" stroke-width="64" opacity="${dark ? 0.85 : 0.55}"/>
    </g>
    <clipPath id="hc"><use href="#head" transform="${T}"/></clipPath>
    <clipPath id="wc"><use href="#wing" transform="${T}"/></clipPath>
  </defs>
  <use href="#scene"/>
  ${stars.join('')}
  ${orbs.join('')}
  <g mask="url(#neck)">
    <use href="#wing" transform="${T}" filter="url(#shade)"/>
    <g clip-path="url(#wc)">
      <g filter="url(#lensblur)" transform="translate(${P.wl[0]} ${P.wl[1]}) scale(1.15) translate(-${P.wl[0]} -${P.wl[1]})"><use href="#scene"/></g>
      <use href="#wing" transform="${T}" fill="url(#glassFill)"/>
      <use href="#wing" transform="${T}" filter="url(#inner)"/>
    </g>
    <use href="#wing" transform="${T}" fill="none" stroke="url(#rim)" stroke-width="4"/>
    <use href="#head" transform="${T}" filter="url(#shade)"/>
    <g clip-path="url(#hc)">
      <g filter="url(#lensblur)" transform="translate(${P.hl[0]} ${P.hl[1]}) scale(1.12) translate(-${P.hl[0]} -${P.hl[2]})"><use href="#scene"/></g>
      <g transform="${T}">
        <use href="#head" fill="url(#glassFill)"/>
        <use href="#head" filter="url(#innerDark)"/>
        <use href="#head" filter="url(#inner)"/>
        ${hair}
        ${face}
      </g>
    </g>
    <g transform="${T}">
      <use href="#head" fill="none" stroke="url(#rim)" stroke-width="5"/>
      ${glints}
    </g>
  </g>
</svg>`;
}
fs.writeFileSync('iris-light.svg', svg(false));
fs.writeFileSync('iris-dark.svg', svg(true));
// phones: upright, Iris in the middle under her rainbow
const tall = {W:1080,H:2340,T:'translate(70 880) scale(1.12)',arc:'M -360 1640 A 900 900 0 0 1 1440 1640',wl:[430,1400],hl:[590,1300,1320],ow:900,oh:700,sh:1500,fade:[0.74,0.9]};
fs.writeFileSync('iris-light-tall.svg', svg(false, tall));
fs.writeFileSync('iris-dark-tall.svg', svg(true, tall));
