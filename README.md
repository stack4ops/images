# zot via Nix Flake


## 1. Bootstrap hashes

`flake.nix` contains placeholder hashes for `src.hash` and `vendorHash`. Sequence:

```sh
nix build .#zot
```

The first error gives you the correct `src` hash (format `got: sha256-...`):

```
error: hash mismatch in fixed-output derivation '...':
         specified: sha256-0000000000000000000000000000000000000000000=
            got:    sha256-AbCdEf...
```

→ Replace `hash` in `flake.nix` with the `got:` value, run `nix build .#zot` again. The second error gives you the `vendorHash` the same way. Enter both values, then the build succeeds.

Alternative: `nix-prefetch-github project-zot zot --rev v2.1.15` to get the `src` hash in advance.

## 2. Build and verify the binary

```sh
nix build .#zot
./result/bin/zot --version
```

## 3. Build the OCI image

```sh
nix build .#image
```

The result is a tarball symlink `result`, not an image in the local Docker daemon — it needs to be loaded first:

```sh
docker load < result
docker images | grep zot
```

## 4. Start locally with Compose

```sh
docker compose up -d
docker compose logs -f zot
```

in a second shell tab 

```sh
curl http://localhost:5000/v2/
```

Check logs in the first shell tab. Should contain something like this:

```sh
level":"info","message":"HTTP API","module":"http","component":"session","clientIP":"172.18.0.1:39472","method":"GET","path":"/v2/","statusCode":200,"latency":"0s","bodySize":0,"headers":{"Accept":["*/*"],"User-Agent":["curl/8.20.0"]},"caller":"zotregistry.dev/zot/v2/pkg/api/session.go:92","func":"zotregistry.dev/zot/v2/pkg/api.SessionLogger.func1.1","goroutine":70}
```

`config.json` sits in the same directory and is mounted read-only — the storage path `/var/lib/registry` is set to match the Compose volume.

## 5. Push test against the local instance

```sh
nix develop   # adds regctl to the shell PATH
regctl --host reg=localhost:5000,tls=disabled image copy alpine:latest localhost:5000/alpine:latest
regctl --host reg=localhost:5000,tls=disabled manifest get localhost:5000/alpine:latest
```

## 6. Shutdown compose stack

```sh
docker compose down
```

## Notes

- `subPackages = [ "cmd/zot" ]` builds the minimal variant without extensions (sync, search, scrub, ui, mgmt, imagetrust, events). For full functionality, enable the `tags` line in `flake.nix` — increases build time and binary size.

- Image is `from scratch` + `cacert` — no base OS, no shell in the container (no `docker exec -it ... sh`).

- `buildImage` instead of `buildLayeredImage`: deliberate choice. The image has
  only two components (zot binary, cacert), and the binary changes on every
  version bump, so layer-level pull caching saves at most the size of cacert
  (a few hundred KB) — negligible against the binary itself. 
  
  More layers also means more overlayfs mounts to unpack and assemble at container
  start, a small but real cost on the other side of the trade-off. 
  
  Revisit if this becomes one of several shared-base Go-binary images in the registry, where
  cross-image layer dedup would start to matter more than the mount overhead.
