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
  tag = "latest";

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
    Env = [ "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt" ];
  };

  meta.image-format = "docker";
}
