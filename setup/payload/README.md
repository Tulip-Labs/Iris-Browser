The build scripts put the compressed app (Iris.exe.gz) and the page engine
(electron.zip, Electron with Iris's helper) here before building the setup,
which embeds them. A setup built without them says so instead of installing.
