# Iris in a container (Podman or Docker)

The image is published for each release on GitHub's registry, and on Docker
Hub and Quay.io when the repository has their secrets (see
`.github/workflows/container.yml`). Podman has no hub of its own: it pulls
from all three.

| Registry | Image |
|---|---|
| GitHub | `ghcr.io/tulip-labs/iris-browser` |
| Docker Hub | `docker.io/<account>/iris-browser` (when `DOCKERHUB_USERNAME` is set) |
| Quay.io | `quay.io/<account>/iris-browser` (when `QUAY_USERNAME` is set) |

## Run

On a Wayland desktop:

```sh
podman pull ghcr.io/tulip-labs/iris-browser:latest
packaging/container/iris-podman            # or: iris-podman https://example.com
```

The script shares your Wayland socket, the GPU (`/dev/dri`) and the sound
socket, keeps Iris's settings and sign-ins in the `iris-home` volume and
saves downloads to your Downloads folder. `IRIS_IMAGE` picks another image
(Docker Hub's, Quay's, or one you built).

## Build

```sh
podman build -f packaging/container/Containerfile -t iris-browser .
IRIS_IMAGE=localhost/iris-browser packaging/container/iris-podman
```

## Limits

- **Sandboxes.** WebKit (bubblewrap) and Electron (Chromium's sandbox) both
  need user namespaces inside the container. Rootless Podman usually allows
  them. When WebKit's sandbox cannot start, Iris leaves WebKit out and
  Electron draws every page; when neither can, Iris says the engines did not
  start. Iris never turns a sandbox off on its own: `IRIS_NO_SANDBOX=1`
  (`iris-podman` passes your environment's value with `-e IRIS_NO_SANDBOX`)
  does, at your choice and risk.
- **Desktop links.** The container cannot become your default browser, and
  opening a link from another program does not reach it.
- **Updates** come with a new image (`podman pull`), not from Iris.

Flatpak remains the recommended way to install Iris on Linux.
