The build scripts put the compressed app here (Iris.exe.gz) before building
the setup, which embeds it. A setup built without it says so instead of installing.

The setup also carries the page engine's helper here, and the Electron
version it was built with:

- `electron-helper/` — Iris's helper (webview/electron/helper: main.js,
  preload.js, package.json, and the node_modules installed for it). The
  setup writes it into the install folder as electron/resources/app.
- `ELECTRON_VERSION` — one line, the Electron version (e.g. `38.1.2`, no
  leading v). The setup downloads that Electron Windows build at install
  time; without this file it takes the latest release instead.
