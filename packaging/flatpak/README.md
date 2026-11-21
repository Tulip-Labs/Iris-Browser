# Iris as a Flatpak

`io.github.tulip_labs.Iris.yml` builds Iris from `linux/` (Swift, swift-adwaita
and WebKitGTK) with the GNOME 50 SDK and Flathub's Swift 6 SDK extension.
CI builds it on every push (`.github/workflows/linux.yml`, job `flatpak`), and
each release carries the bundle, `Iris-x86_64.flatpak`:

    flatpak install --user Iris-x86_64.flatpak

The bundle needs the GNOME 50 runtime, which Flatpak installs from Flathub
when the Flathub remote is set up (`flatpak remote-add --if-not-exists --user
flathub https://dl.flathub.org/repo/flathub.flatpakrepo`).

To build it yourself:

    flatpak install --user flathub org.gnome.Sdk//50 org.freedesktop.Sdk.Extension.swift6//25.08
    flatpak-builder --user --install --force-clean build packaging/flatpak/io.github.tulip_labs.Iris.yml

## Flathub

Flathub builds without network access, so a Flathub manifest lists every
source (swift-adwaita and the packages it uses, at fixed revisions), and
Flathub asks that manifests and submissions be made by people, not AI tools.
That submission is for a person on the team to prepare.

## The page sandbox

Pages run inside Flatpak's sandbox, and WebKitGTK keeps its own sandbox for
its web processes inside it (through flatpak-spawn).

## Glass and the compositor

The window is translucent. Where the compositor offers background blur
through the `ext-background-effect-v1` protocol (niri 26.04 and newer, and
others that adopt it), Iris asks for it, shaped like the window; elsewhere
the window stays nearly solid.
