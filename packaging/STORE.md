# Publishing Iris in the Microsoft Store

The Store is the way to get Iris signed for free: Microsoft signs the MSIX package
itself after checking it, so it installs without the "Windows protected your PC" warning
and updates on its own. Registration is free for individual developers.

Only you can do steps 1 and 2: Microsoft checks your identity with an ID document and a
selfie.

## 1. Register (once)

1. Go to https://storedeveloper.microsoft.com and sign in with a personal Microsoft account.
2. Choose **Individual** and follow the identity check (government ID and a selfie). No
   card is asked for.
3. Pick the publisher name people will see: `Tulipan Labs`.

## 2. Reserve the name and copy the identity

1. In Partner Center: **Apps and games > New product > MSIX or PWA app**, name `Iris`.
2. Open **Product identity** and copy two values into `packaging/msix.json`:
   - `Package/Identity/Name` goes in `"name"`
   - `Package/Identity/Publisher` goes in `"publisher"` (it looks like `CN=XXXXXXXX-XXXX-...`)
   - `Package/Properties/PublisherDisplayName` goes in `"publisherDisplayName"`
3. Commit that file, then run the **Release** workflow (Actions tab) with a new tag. The
   release will contain a `Iris.msixbundle` built with your identity. A package built
   with the placeholder identity is refused by the Store.

## 3. Fill in the submission

| Section | What to enter |
|---|---|
| Pricing and availability | Free, all markets |
| Properties: category | Productivity |
| Properties: privacy policy URL | `https://github.com/Tulip-Labs/Iris-Browser/blob/main/PRIVACY.md` |
| Properties: website | `https://github.com/Tulip-Labs/Iris-Browser` |
| Properties: support contact | `https://github.com/Tulip-Labs/Iris-Browser/issues` |
| Age ratings | Answer the questionnaire: a browser gives unrestricted access to the internet, so say so |
| Packages | Upload `Iris.msixbundle` from the release |
| Store listing | The texts below, and screenshots from `assets/screens` |

The package asks for the `runFullTrust` capability (it is a desktop program). Partner
Center asks why; answer:

> Iris is a desktop web browser written in Go. It ships its own page engines
> (Servo and Electron) to show web pages and needs full trust to create its
> window, run them and save downloads.

## Listing text

**Short description**

> A light, fast browser. Low memory, built-in ad and tracker blocking, split view, and a
> sandbox for unsafe sites.

**Description**

> Iris is a small browser that ships its own page engines (Servo and
> Electron), so it works the same on every PC and stays light on memory.
>
> - Iris Shields remove ads, trackers and cookie notices, and learn which sites need them.
> - Background tabs give memory back, sleep, and unload on their own.
> - Split view shows two pages side by side.
> - A download manager, find in page, zoom, print and history.
> - Private, temporary and container tabs, and a sandbox for addresses that look unsafe.
> - Send files between your PC and your phone by scanning a QR code, with nothing to
>   install on the phone.
> - Eleven color palettes, including soft pastel gradients and a night mode.
>
> Iris is free and open source (GPL 3.0). It has no account, no telemetry and no ads.

**Search terms:** browser, web browser, ad blocker, privacy, lightweight, split view, fast

## winget installs the same bundle

`winget install TulipLabs.Iris` installs the `Iris.msixbundle` from the release — the
same file uploaded to the Store. The release workflow makes the winget manifests and,
when the `WINGET_TOKEN` secret is set, submits them to microsoft/winget-pkgs. One
condition: the bundle has to be signed first (see below), or `winget` cannot install it
on a normal PC. The Store signs its own copy, so the Store listing works with or
without that step.

## What the Store does not cover

Windows is MSIX-only now: there is no setup `.exe` and no portable `.zip` anymore, so
nothing unsigned is handed out. One thing still needs a signature: the bundle `winget`
installs. The Store signs the copy it distributes, but the bundle on the GitHub release
is unsigned until someone signs it, and `winget` cannot install an unsigned MSIX on a
normal PC. Signing it needs a certificate:

- **SignPath Foundation** signs open-source projects for free. Iris's GPL license
  qualifies in principle; they review each project. Apply at https://signpath.org
  (this is the route to take: once the release bundle is signed, the Store submission
  and `winget install TulipLabs.Iris` use the same file)
- **Azure Artifact Signing** costs about 10 USD a month, and for individuals is open only
  in the USA and Canada.
- A certificate from a certificate authority costs roughly 150 to 300 USD a year.

Even signed, a new file shows the warning until enough people have run it. The Store
package is the only route with no warning from the first day.
