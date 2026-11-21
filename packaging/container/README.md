# Iris in a container (Podman or Docker)

Each release publishes Iris's image to GitHub's registry, and to Docker Hub
and Quay.io when the repository has their secrets (see
`.github/workflows/container.yml`). Podman has no hub of its own: it pulls
from all three, as Docker does.

| Registry | Image |
|---|---|
| GitHub | `ghcr.io/tulip-labs/iris-browser` |
| Docker Hub | `docker.io/<account>/iris-browser` (when `DOCKERHUB_USERNAME` is set) |
| Quay.io | `quay.io/<account>/iris-browser` (when `QUAY_USERNAME` is set) |

## Run

On a Wayland desktop, with `iris-container` (in each release, and here):

```sh
podman pull ghcr.io/tulip-labs/iris-browser:latest
sh iris-container                    # or: sh iris-container https://example.com
```

It uses Podman, or Docker when Podman is not there. `IRIS_IMAGE` picks
another image (Docker Hub's, Quay's, or one you built).

## Performance

The container runs Iris at the same pace as the Flatpak: there is no
virtual machine, only namespaces, and the launcher gives the browser what it
needs:

| What | How |
|---|---|
| GPU drawing (OpenGL, Vulkan) | `/dev/dri` (Intel, AMD: Mesa in the image); NVIDIA through CDI when `nvidia-ctk cdi generate` was run on the host |
| Video decoding on the GPU | Mesa's VA-API drivers in the image, used by WebKit's GStreamer; OpenH264 and libav for H.264 and AAC |
| Frames between WebKit's processes | `--shm-size=2g` (the default 64 MB is too little for video) |
| WebKit's processes | `--init` reaps them |
| Cache between runs | the `iris-home` volume keeps the page cache, Mesa's shader cache and the font cache warm |
| Start time | the font cache is built into the image |
| Network | Podman's default (pasta) runs at the host's speed |

## Build

```sh
podman build -f packaging/container/Containerfile -t iris-browser .
IRIS_IMAGE=localhost/iris-browser sh packaging/container/iris-container
```

## Limits

- **Sandbox.** WebKit runs its web processes in a bubblewrap sandbox, which
  needs user namespaces inside the container; rootless Podman usually allows
  them. Where it cannot run, Iris says so instead of showing pages. Iris
  never turns the sandbox off on its own: `IRIS_NO_SANDBOX=1` (passed into
  the container when set) does, at your choice and risk.
- **Docker** runs Iris as your user; if your user id is not 1000, the
  `iris-home` volume made by Docker may need `docker volume rm iris-home`
  and a new start.
- **Desktop links.** The container cannot become your default browser, and
  opening a link from another program does not reach it.
- **Updates** come with a new image (`podman pull`), not from Iris.
