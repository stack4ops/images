# stack4ops/images

OCI images, built with Nix and published by argunix.

This repository holds image plumbing only. The packages the images are built
from, and the NixOS modules that run them outside a container, live in
[stack4ops/pkgs](https://github.com/stack4ops/pkgs); this flake applies that
repository's overlay and composes `ociImages` on top of it. The split and its
reasoning are ADR-010.

| Path | What |
|---|---|
| `images/zot.nix` | zot as a loadable docker-archive, `from scratch` + cacert |
| `overlay.nix` | composes `pkgs.ociImages` |
| `tests/image-structure.nix` | archive assertions, no VM, no KVM |
| `tests/image.nix` | behavioural test through Docker (needs KVM) |
| `compose.yml`, `config.json` | local run of the built image |

## Adding an image

1. Make sure the package exists in stack4ops/pkgs and is exposed by its
   overlay.
2. Add `images/<name>.nix`, taking that package as an argument.
3. Add one line to `overlay.nix`:
   `<name> = final.callPackage ./images/<name>.nix { };`
4. Set `meta.image-format = "docker"` on the derivation. That is the single
   attribute argunix reads to decide an output is to be published rather than
   merely built.

The attribute name is the registry path. `ociImages.zot` lands at
`<registry>/<namespace>/zot`. The `name` and `tag` inside `buildImage` are
internal to the archive and do not appear in the registry.

`"docker"` rather than `"oci"`: dockerTools produces a docker-archive, and it
is the format argunix may *assemble* -- exposing the same attribute name once
per system makes argunix stitch the per-arch results into one multi-arch image
index. An `"oci"` output is a finished image argunix pushes untouched, and
exposing it under several systems is a clash.

## Build and run locally

```sh
nix build .#zot
docker load < result
docker compose up -d
curl http://localhost:5000/v2/
```

`config.json` in this directory is mounted read-only by `compose.yml`. The
image bakes in no config on purpose: a registry's storage layout and auth
belong to the deployment. On NixOS use `services.zot` from stack4ops/pkgs
instead -- that runs the binary directly and generates the config from
options.

There is no `packages.default`. Aliasing an image to `default` would inherit
its `meta.image-format` and publish the same artefact twice, once under the
name "default". Build by name.

## Tests

```sh
nix build .#checks.x86_64-linux.zot-image-structure
```

`image-structure` reads the published archive and asserts on the entrypoint,
the mount path in `Cmd`, the exposed port, the presence of the CA bundle that
`SSL_CERT_FILE` points at, and the absence of any shell in `/bin`. It is a
plain derivation, so it runs on any builder and gates every push.

`image.nix` is the behavioural test: load into Docker, start with a mounted
config and volume, push, attach a referrer through the containerised registry,
restart, confirm the data survives and no shell is reachable. It is `runNixOSTest`
and needs `/dev/kvm`, so it is commented out in `flake.nix` until a builder with
the device is enrolled. An argunix builder that cannot verify `/dev/kvm` no
longer advertises the feature, so leaving it enabled means the check sits
unscheduled rather than failing with a confusing TCG boot log.

A red check does not hold back the push either way: argunix publishes an image
when its own job succeeds, and checks are separate top-level jobs.

## Notes on the image

- `from scratch` plus `cacert`. No base OS, no shell -- `docker exec -it ... sh`
  will not work, by design, and `tests/image-structure.nix` pins it.
- `buildImage` rather than `buildLayeredImage`: the image has two components
  and the binary changes on every version bump, so layer-level pull caching
  saves at most the size of cacert against the mount overhead of more layers.
  Revisit if this becomes one of several shared-base Go-binary images, where
  cross-image layer dedup would start to matter more.
