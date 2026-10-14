# Image overlay.
#
# This overlay is NOT self-sufficient. It builds from `zot`, which
# stack4ops/pkgs provides, so it must be applied after that repository's
# overlay:
#
#   overlays = [
#     inputs.stack4ops-pkgs.overlays.default
#     inputs.stack4ops-images.overlays.default
#   ];
#
# The dependency is left explicit rather than importing the package overlay
# from in here. Importing it would make this overlay look standalone while
# quietly applying a second copy for consumers who already apply it
# themselves, and would hide which repository a given attribute comes from.
final: prev: {
  # Images live in their own namespace so the flake can expose the whole set
  # as `packages` without colliding with the packages they are built from.
  #
  # `prev.ociImages or { }` composes with other image overlays instead of
  # replacing their set -- but only if the other one does the same. An overlay
  # that assigns `ociImages` flat drops whatever came before it, so ordering
  # matters if further image sets ever land in this repository.
  ociImages = (prev.ociImages or { }) // {
    # final.callPackage, not prev: `zot` comes from the package overlay, and
    # final is where overlays see each other's results.
    zot = final.callPackage ./images/zot.nix { };
  };
}
