# The zot registry as a loadable OCI image.
#
# `meta.image-format = "docker"` is the one attribute argunix reads to decide
# this output should be published to a registry rather than treated as an
# ordinary package. "docker" rather than "oci" because dockerTools produces a
# docker-archive, and because it is the format argunix may ASSEMBLE: exposing
# the same attribute name once per system makes argunix stitch the per-arch
# results into one multi-arch image index. An "oci" output is a finished image
# argunix pushes untouched, and exposing it under several systems is a clash.
#
# The registry path does NOT come from `name`/`tag` below -- those are internal
# to the archive. It is <registry>/<namespace>/<attribute-name>, so this image
# lands at .../zot because the overlay names it `ociImages.zot`.
{
  dockerTools,
  buildEnv,
  cacert,
  zot,
}:

dockerTools.buildImage {
  name = "zot";
  # Internal to the archive only (docker load, compose.yml). argunix ignores it
  # and tags the registry copy with branch, latest and sha-<short>.
  tag = zot.version;

  copyToRoot = buildEnv {
    name = "zot-image-root";
    paths = [
      zot
      cacert
    ];
    pathsToLink = [
      "/bin"
      "/etc"
    ];
  };

  config = {
    Entrypoint = [ "/bin/zot" ];

    # No config.json is baked in: a registry's storage layout and auth belong
    # to the deployment, not to the image. Mount one at this path, or override
    # Cmd. On NixOS use the module instead -- it runs the binary directly and
    # generates the config from options.
    Cmd = [
      "serve"
      "/etc/zot/config.json"
    ];

    ExposedPorts."5000/tcp" = { };

    # The registry tags carry no version (branch, latest, sha-<short>), so the
    # upstream version travels in the image config instead. Readable with
    # `skopeo inspect` or `regctl image config` on any pinned digest.
    Labels = {
      "org.opencontainers.image.title" = "zot";
      "org.opencontainers.image.version" = zot.version;
      "org.opencontainers.image.url" = zot.meta.homepage;
      "org.opencontainers.image.licenses" = "Apache-2.0";
    };
    Env = [ "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt" ];
  };

  meta.image-format = "docker";
}
