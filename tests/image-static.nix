# Static check of the published image archive. Runs without KVM: it unpacks
# the docker-archive that argunix pushes and asserts on its metadata and
# layer contents, without starting anything.
#
# Complements tests/image.nix, which does start the image but needs a VM.
# What can be decided from the archive alone is decided here, so it keeps
# guarding the image while the VM tests cannot run.
{
  runCommand,
  jq,
  ociImages,
  zot,
}:

runCommand "zot-image-static-check"
  {
    nativeBuildInputs = [ jq ];
    image = ociImages.zot;
    expectedVersion = zot.version;
  }
  ''
    mkdir img
    tar -xf "$image" -C img

    manifest=img/manifest.json
    config="img/$(jq -r '.[0].Config' "$manifest")"

    fail() { echo "FAIL: $*" >&2; exit 1; }

    echo "archive tag matches the packaged version"
    tag=$(jq -r '.[0].RepoTags[0]' "$manifest")
    [ "$tag" = "zot:$expectedVersion" ] || fail "archive tag is $tag"

    echo "version label matches the packaged version"
    label=$(jq -r '.config.Labels["org.opencontainers.image.version"] // empty' "$config")
    [ "$label" = "$expectedVersion" ] || fail "version label is '$label'"

    echo "entrypoint is zot"
    jq -e '.config.Entrypoint == ["/bin/zot"]' "$config" > /dev/null \
      || fail "entrypoint is $(jq -c .config.Entrypoint "$config")"

    # List every layer into one file first, then grep the file. Piping
    # `tar -t` straight into `grep -q` is wrong here: stdenv runs builders
    # with `set -o pipefail`, grep -q exits on the first match, tar dies of
    # SIGPIPE, and the pipeline reports failure exactly when grep matched.
    # That inverted both checks below -- including the shell check, which
    # then passed even with a shell present.
    for layer in $(jq -r '.[0].Layers[]' "$manifest"); do
      tar -tf "img/$layer" | sed 's#^\./##' >> files.txt
    done

    echo "CA bundle path from the image env exists in a layer"
    cert=$(jq -r '.config.Env[] | select(startswith("SSL_CERT_FILE=")) | sub("^SSL_CERT_FILE=/"; "")' "$config")
    [ -n "$cert" ] || fail "SSL_CERT_FILE not set"
    grep -qxF "$cert" files.txt || fail "$cert not present in any layer"

    echo "no shell or interpreter anywhere in the image"
    # Matches /bin/sh and /bin/bash at the root as well as any bash or sh that
    # a closure addition would drag in under /nix/store.
    if shells=$(grep -E '(^|/)bin/(sh|bash|dash|busybox)$' files.txt); then
      fail "shell found: $(echo "$shells" | head -n 3 | tr '\n' ' ')"
    fi

    touch "$out"
  ''
