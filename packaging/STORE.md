# Publishing Lite Go in the Microsoft Store

The Store is the way to get Lite Go signed for free: Microsoft signs the MSIX package
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

1. In Partner Center: **Apps and games > New product > MSIX or PWA app**, name `Lite Go`.
2. Open **Product identity** and copy two values into `packaging/msix.json`:
   - `Package/Identity/Name` goes in `"name"`
   - `Package/Identity/Publisher` goes in `"publisher"` (it looks like `CN=XXXXXXXX-XXXX-...`)
   - `Package/Properties/PublisherDisplayName` goes in `"publisherDisplayName"`
3. Commit that file, then run the **Release** workflow (Actions tab) with a new tag. The
   release will contain a `LiteGo.msixbundle` built with your identity. A package built
   with the placeholder identity is refused by the Store.

## 3. Fill in the submission

| Section | What to enter |
|---|---|
| Pricing and availability | Free, all markets |
| Properties: category | Productivity |
| Properties: privacy policy URL | `https://github.com/Tulip-Labs/Lite-Go-Browser/blob/main/PRIVACY.md` |
| Properties: website | `https://github.com/Tulip-Labs/Lite-Go-Browser` |
| Properties: support contact | `https://github.com/Tulip-Labs/Lite-Go-Browser/issues` |
| Age ratings | Answer the questionnaire: a browser gives unrestricted access to the internet, so say so |
| Packages | Upload `LiteGo.msixbundle` from the release |
| Store listing | The texts below, and screenshots from `assets/screens` |

The package asks for the `runFullTrust` capability (it is a desktop program). Partner
Center asks why; answer:

> Lite Go is a desktop web browser written in Go. It hosts Microsoft Edge WebView2 to show
> web pages and needs full trust to create its window, run WebView2 and save downloads.

## Listing text

**Short description**

> A light, fast browser. Low memory, built-in ad and tracker blocking, split view, and a
> sandbox for unsafe sites.

**Description**

> Lite Go is a small browser that uses the web engine Windows already has (Microsoft Edge
> WebView2), so it installs in seconds and stays light on memory.
>
> - Lite Shields remove ads, trackers and cookie notices, and learn which sites need them.
> - Background tabs give memory back, sleep, and unload on their own.
> - Split view shows two pages side by side.
> - A download manager, find in page, zoom, print and history.
> - Private, temporary and container tabs, and a sandbox for addresses that look unsafe.
> - Send files between your PC and your phone by scanning a QR code, with nothing to
>   install on the phone.
> - Eleven color palettes, including soft pastel gradients and a night mode.
>
> Lite Go is free and open source (GPL 3.0). It has no account, no telemetry and no ads.

**Search terms:** browser, web browser, ad blocker, privacy, lightweight, split view, fast

## What the Store does not cover

The setup `.exe` and the portable `.zip` on GitHub stay unsigned, so SmartScreen warns
about them. Signing those needs a certificate:

- **SignPath Foundation** signs open-source projects for free. Lite Go's GPL license
  qualifies in principle; they review each project. Apply at https://signpath.org
- **Azure Artifact Signing** costs about 10 USD a month, and for individuals is open only
  in the USA and Canada.
- A certificate from a certificate authority costs roughly 150 to 300 USD a year.

Even signed, a new file shows the warning until enough people have run it. The Store
package is the only route with no warning from the first day.
