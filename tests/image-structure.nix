# Derivation-level checks on the archive this repository publishes.
#
# Unlike tests/image.nix this needs no VM and therefore no /dev/kvm, so it
# runs on any builder. It is not a substitute for that test: it cannot tell
# you whether the registry actually serves anything. What it does catch is the
# class of mistake that is both easy to make and invisible until deployment --
# an entrypoint that no longer points at the binary, a dropped SSL_CERT_FILE,
# a CA bundle the config references but the image does not carry, a shell that
# crept in through a careless `copyToRoot` addition.
#
# The assertions read the docker-archive layout that dockerTools.buildImage
# emits: a manifest.json whose first entry names a Config file and a list of
# Layers. That layout is stable but not contractual. If nixpkgs changes it,
# this check fails loudly rather than passing silently, which is the correct
# failure direction for a test.
{
  runCommand,
  jq,
  gnutar,
  ociImages,
}:

runCommand "zot-image-structure"
  {
    nativeBuildInputs = [
      jq
      gnutar
    ];
    image = ociImages.zot;
  }
  ''
    mkdir -p archive

    # No -z: GNU tar detects the compression itself, so this works whether or
    # not buildImage gzipped the archive, and keeps working if that default
    # changes.
    tar -xf "$image" -C archive

    if [ ! -f archive/manifest.json ]; then
      echo "FAIL: no manifest.json in the archive -- has the layout changed?" >&2
      find archive -maxdepth 2 >&2
      exit 1
    fi

    configPath=$(jq -r '.[0].Config' archive/manifest.json)
    if [ ! -f "archive/$configPath" ]; then
      echo "FAIL: manifest names config '$configPath', which is not in the archive" >&2
      exit 1
    fi
    cp "archive/$configPath" config.json

    fail=0
    note() {
      echo "FAIL: $1" >&2
      fail=1
    }

    # --- image config -------------------------------------------------------

    entrypoint=$(jq -r '.config.Entrypoint // [] | join(" ")' config.json)
    [ "$entrypoint" = "/bin/zot" ] \
      || note "entrypoint is '$entrypoint', expected '/bin/zot'"

    # The image bakes in no config file on purpose -- storage layout and auth
    # belong to the deployment -- so Cmd is what tells an operator where to
    # mount one. Changing the path silently breaks every compose file and
    # every Kubernetes manifest that mounts it.
    cmd=$(jq -r '.config.Cmd // [] | join(" ")' config.json)
    [ "$cmd" = "serve /etc/zot/config.json" ] \
      || note "cmd is '$cmd', expected 'serve /etc/zot/config.json'"

    jq -e '.config.ExposedPorts | has("5000/tcp")' config.json >/dev/null \
      || note "5000/tcp is not declared in ExposedPorts"

    certPath=$(
      jq -r '.config.Env // [] | map(select(startswith("SSL_CERT_FILE="))) | .[0] // ""' config.json \
        | cut -d= -f2-
    )
    # Without it, outbound TLS from the container fails at runtime with an
    # error that points nowhere useful.
    if [ -z "$certPath" ]; then
      note "SSL_CERT_FILE is not set in the image config"
    fi

    # --- layer contents -----------------------------------------------------

    layers=$(jq -r '.[0].Layers // [] | .[]' archive/manifest.json)
    if [ -z "$layers" ]; then
      echo "FAIL: manifest lists no layers" >&2
      exit 1
    fi

    for layer in $layers; do
      if [ ! -f "archive/$layer" ]; then
        echo "FAIL: manifest lists layer '$layer', which is not in the archive" >&2
        exit 1
      fi
      tar -tf "archive/$layer"
    done > entries

    grep -Eq '(^|/)bin/zot$' entries \
      || note "no bin/zot in any layer -- the entrypoint has nothing to run"

    # Not incidental, and the single most valuable assertion here: /bin holds
    # the zot binary and nothing else, so a command-injection foothold has no
    # interpreter to build on.
    if grep -Eq '(^|/)bin/(sh|bash|dash|ash|busybox)$' entries; then
      note "a shell is present in the image:"
      grep -E '(^|/)bin/(sh|bash|dash|ash|busybox)$' entries >&2
    fi

    if [ -n "$certPath" ]; then
      grep -Fq "''${certPath#/}" entries \
        || note "SSL_CERT_FILE points at $certPath, which no layer provides"
    fi

    # ------------------------------------------------------------------------

    if [ "$fail" -ne 0 ]; then
      echo "" >&2
      echo "image config was:" >&2
      jq '.config' config.json >&2
      exit 1
    fi

    echo "entrypoint, cmd, exposed port, CA bundle and shell-free /bin all check out"
    touch "$out"
  ''
