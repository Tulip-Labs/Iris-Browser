# Iris as a Flatpak

`io.github.tulip_labs.Iris.yml` packages `dist/linux` (made by
`./build-iris.sh linux`). CI builds it on every push (`.github/workflows/linux.yml`,
job `flatpak`) and each release carries the bundle, `Iris-x86_64.flatpak`:

    flatpak install --user Iris-x86_64.flatpak

The bundle needs the GNOME 50 runtime, which Flatpak installs from Flathub
when the Flathub remote is set up (`flatpak remote-add --if-not-exists --user
flathub https://dl.flathub.org/repo/flathub.flatpakrepo`).

## Why the bundle is built from dist/linux

The release bundle holds exactly the files CI built and tested, and builds in
minutes. Flathub builds every app from source without network access, so a
Flathub manifest lists every download: the engine (Chromium, CEF; checksums
in `packaging/cef/cef.env`) and each Go module. `go run tools/flatpaksrc.go >
packaging/flatpak/go-sources.json` writes the Go part: each module's .info,
.mod and .zip from the Go module proxy with its SHA-256, laid out as a module
proxy (`GOPROXY=file://$PWD/goproxy`), so `go build` runs offline and still
checks go.sum.

## Chromium's sandbox

The pages run inside Flatpak's sandbox. Chromium's own sandbox inside it
needs zypak, which the bundle carries: the Electron engine starts through it.
The current engine (CEF) starts its page processes through a helper program
of its own, which zypak cannot run yet, so it starts with `IRIS_NO_SANDBOX=1`
(Flatpak's sandbox only) until the Electron engine replaces it.
