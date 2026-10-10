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

    echo "CA bundle path from the image env exists in a layer"
    cert=$(jq -r '.config.Env[] | select(startswith("SSL_CERT_FILE=")) | sub("^SSL_CERT_FILE=/"; "")' "$config")
    [ -n "$cert" ] || fail "SSL_CERT_FILE not set"
    found=
    for layer in $(jq -r '.[0].Layers[]' "$manifest"); do
      tar -tf "img/$layer" | sed 's#^\./##' | grep -qx "$cert" && found=1
    done
    [ -n "$found" ] || fail "$cert not present in any layer"

    echo "no shell or interpreter anywhere in the image"
    # Matches /bin/sh and /bin/bash at the root as well as any bash or sh that
    # a closure addition would drag in under /nix/store.
    for layer in $(jq -r '.[0].Layers[]' "$manifest"); do
      if tar -tf "img/$layer" | grep -Eq '(^|/)bin/(sh|bash|dash|busybox)$'; then
        fail "shell found in $layer"
      fi
    done

    touch "$out"
  ''
