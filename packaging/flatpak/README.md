# Iris as a Flatpak

`io.github.tulip_labs.Iris.yml` builds WPE WebKit 2.54.3 (with WPEPlatform)
and then Iris from `linux/` (Zig 0.15.2, GTK 4 and libadwaita) with the GNOME
50 SDK. WPE takes a few hours the first time; CI keeps it in its cache.
CI builds it on every push (`.github/workflows/linux.yml`, job `flatpak`), and
each release carries the bundle, `Iris-x86_64.flatpak`:

    flatpak install --user Iris-x86_64.flatpak

The bundle needs the GNOME 50 runtime, which Flatpak installs from Flathub
when the Flathub remote is set up (`flatpak remote-add --if-not-exists --user
flathub https://dl.flathub.org/repo/flathub.flatpakrepo`).

To build it yourself:

    flatpak install --user flathub org.gnome.Sdk//50
    flatpak-builder --user --install --force-clean build packaging/flatpak/io.github.tulip_labs.Iris.yml

## Flathub

Every source in the manifest is fixed by checksum or commit (WPE WebKit,
woff2, Zig), and
Flathub asks that manifests and submissions be made by people, not AI tools.
That submission is for a person on the team to prepare.

## The page sandbox

Pages run inside Flatpak's sandbox, and WPE WebKit keeps its own sandbox for
its web processes inside it (through flatpak-spawn).

## Glass and the compositor

The window is translucent. Where the compositor offers background blur
through the `ext-background-effect-v1` protocol (niri 26.04 and newer, and
others that adopt it), Iris asks for it, shaped like the window; elsewhere
the window stays nearly solid.
