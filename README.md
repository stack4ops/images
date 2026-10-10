# zot via Nix flake

zot OCI registry as a Nix package, a NixOS module and an OCI image. Built and
published by argunix.

| Flake output | What it is |
| --- | --- |
| `packages.<system>.zot` | The OCI image (docker-archive). argunix pushes it as `<registry>/<namespace>/zot`. |
| `packages.<system>.zot-bin` | The zot binary (minimal build, no extensions). |
| `nixosModules.zot` | NixOS module, uses `pkgs.zot` from `overlays.default`. |
| `checks.<system>.zot-image-static` | Image archive check, runs without KVM. |
| `checks.x86_64-linux.zot-referrers`, `zot-image` | VM tests, need KVM. Off until `withVmTests = true` in `flake.nix`. |

## Build and verify the binary

```sh
nix build .#zot-bin
./result/bin/zot --version
```

The output carries the version as `commit` (e.g. `v2.1.17`), plus
`binary-type: minimal` and the Go version. The build fails if it does not:
`versionCheckHook` runs `zot --version` as part of the package.

## Build the OCI image

```sh
nix build .#zot
docker load < result
docker images | grep zot
```

`result` is a tarball, not an image in the local Docker daemon, hence the
`docker load`. The archive is tagged `zot:<version>`; on the registry argunix
tags it `<branch>`, `latest` (default branch) and `sha-<short>` instead.

The version travels in the image config as OCI labels, so it is readable on
any pinned digest:

```sh
skopeo inspect docker://<registry>/<namespace>/zot@sha256:<digest> \
  | jq -r '.Labels["org.opencontainers.image.version"]'
```

## Start locally with Compose

```sh
docker compose up -d
docker compose logs -f zot
curl http://localhost:5000/v2/
```

`config.json` is mounted read-only. It binds `0.0.0.0` inside the container
(required for the port mapping) and stores data in `/var/lib/registry`, the
Compose volume. The port is published on loopback only, because this config
has no authentication.

## Push test against the local instance

```sh
nix develop   # regctl, oras, skopeo, crane
regctl --host reg=localhost:5000,tls=disabled image copy alpine:latest localhost:5000/alpine:latest
oras discover --plain-http localhost:5000/alpine:latest
```

## Shut down

```sh
docker compose down
```

## Updates

Renovate runs from the bot repository (stack4ops/renovate) with its shared
preset. It tracks:

- the zot version, via the `# renovate:` comments in `pkgs/zot.nix` and
  `compose.yml` (one PR for both),
- the `nixpkgs` input in `flake.lock` (weekly),
- GitHub Actions, pinned by digest.

Renovate cannot compute Nix hashes. On Renovate branches,
`.github/workflows/nix-hash-fixup.yml` runs `nix-update --version=skip` for
`zot-bin` and pushes the new `hash` and `vendorHash`. argunix then builds the
new head; a green status lets GitHub automerge (patch and minor only, after
3 days).

Manual bump, without Renovate:

```sh
nix run nixpkgs#nix-update -- --flake --version=2.1.20 zot-bin
```

## Notes

- Minimal build: `subPackages = [ "cmd/zot" ]` without extension tags (sync,
  search, scrub, ui, mgmt, imagetrust, events). The Referrers API is part of
  the core and works without them. For the full flavour, enable the `tags`
  line in `pkgs/zot.nix`.

- Image is `from scratch` + `cacert`: no base OS, no shell
  (`zot-image-static` enforces that).

- `buildImage` instead of `buildLayeredImage`: deliberate choice. The image
  has only two components (zot binary, cacert), and the binary changes on
  every version bump, so layer-level pull caching saves at most the size of
  cacert (a few hundred KB). More layers also means more overlayfs mounts at
  container start. Revisit if this becomes one of several shared-base Go
  binary images in the registry, where cross-image layer dedup would matter.
