final: prev: {
  # The binary, as a top-level attribute so NixOS consumers get `pkgs.zot`
  # by applying this overlay -- which is what nix/zot-module.nix defaults to.
  zot = final.callPackage ./pkgs/zot.nix { };

  # Images live in their own namespace so the flake can expose the whole set
  # as `packages` without colliding with the packages they are built from.
  #
  # `prev.ociImages or { }` composes with other image overlays instead of
  # replacing their set -- but only if the other one does the same. An overlay
  # that assigns `ociImages` flat drops whatever came before it, so ordering
  # matters if further image sets ever land in this repository.
  ociImages = (prev.ociImages or { }) // {
    # final.callPackage, not prev: the image needs `zot` from THIS overlay,
    # and prev does not have it yet.
    zot = final.callPackage ./images/zot.nix { };
  };
}
