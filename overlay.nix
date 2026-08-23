_final: prev: {
  # The binary, as a top-level attribute so NixOS consumers get `pkgs.zot`
  # by applying this overlay -- which is what nix/zot-module.nix defaults to.
  zot = prev.callPackage ./pkgs/zot.nix { };

  # Images live in their own namespace so the flake can expose the whole set
  # as `packages` without colliding with the packages they are built from.
  # `prev.ociImages or { }` lets this overlay compose with other image
  # overlays instead of replacing their set.
  ociImages = prev.ociImages or { } // {
    zot = prev.callPackage ./images/zot.nix { };
  };
}
