{
  description = "stack4ops OCI images (argunix-compatible)";

  inputs = {
    # Pinned to the release the consuming host tracks.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    # The packages the images are built from, plus their NixOS modules.
    #
    # `follows` matters here: this flake applies the overlay from there to its
    # OWN nixpkgs, so the nixpkgs pinned over there is never used for
    # anything. Without the follows it would still be fetched and recorded in
    # flake.lock, leaving a second nixpkgs node that drifts from this one
    # while changing nothing. With it, there is exactly one pin -- the one on
    # the line above.
    #
    # Deliberately NOT re-exported from this flake. A consumer who wants
    # `services.zot` takes the module from stack4ops/pkgs directly. Passing it
    # through here would mean two lock files to bump for one zot update, with
    # the system pointing at the older version in between and nothing turning
    # red to say so.
    stack4ops-pkgs = {
      url = "github:stack4ops/pkgs";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs:
    let
      # Explicit and Linux-only. flake-utils' eachDefaultSystem would add the
      # two darwin systems, where dockerTools cannot build an image at all.
      # Unlike stack4ops/pkgs, this restriction is structural rather than a
      # matter of available builders.
      #
      # aarch64-linux is listed so the per-arch outputs exist. Note that
      # argunix only walks the systems in `services.argunix.systems`, so the
      # aarch64 outputs stay invisible to CI until that option lists them too.
      # "aarch64-linux"
      systems = [
        "x86_64-linux"
      ];

      eachSystem =
        systems: f:
        builtins.foldl' (
          acc: system:
          let
            outputs = f system;
          in
          builtins.foldl' (
            acc': name:
            acc'
            // {
              ${name} = (acc'.${name} or { }) // {
                ${system} = outputs.${name};
              };
            }
          ) acc (builtins.attrNames outputs)
        ) { } systems;
    in
    {
      # Images only. This overlay does NOT stand on its own: it builds from
      # `zot`, which stack4ops/pkgs provides, so a consumer applies both, in
      # this order. See overlay.nix.
      overlays.default = import ./overlay.nix;
    }
    // eachSystem systems (
      system:
      let
        pkgs = import inputs.nixpkgs {
          inherit system;
          overlays = [
            # Order is load-bearing: the image overlay resolves `zot` from
            # `final`, which only has it once the package overlay has run.
            inputs.stack4ops-pkgs.overlays.default
            inputs.self.overlays.default
          ];
        };
      in
      {
        # Attribute names here become registry image names: an image exposed
        # as `zot` lands at <registry>/<namespace>/zot. Since this repository
        # exposes nothing but images, the names can be plain -- the `zot-bin`
        # suffix that used to be needed disappeared with the split.
        #
        # No `packages.default`. Aliasing an image to `default` would inherit
        # its meta.image-format and get the same artefact pushed a second time
        # under the name "default"; and there is no non-image output left here
        # to point it at instead. Build by name: `nix build .#zot`.
        packages = pkgs.ociImages;

        devShells.default = pkgs.mkShell {
          packages = [
            # oras is the tool for the referrers work this registry exists to
            # exercise: `oras discover` lists artifacts attached to a
            # manifest, `oras pull` fetches one. regctl alone does not cover
            # it.
            pkgs.oras
            pkgs.regctl
            pkgs.skopeo
            # `crane` is not an attribute in nixpkgs -- the binary ships in
            # go-containerregistry, which declares it as mainProgram.
            pkgs.go-containerregistry
            pkgs.jq
          ];
        };

        checks = {
          # Derivation-level assertions on the archive this repository
          # publishes. No VM, so no /dev/kvm, so this one actually runs on the
          # dev instance's builder -- which is why it exists: the behavioural
          # test below cannot run there yet, and shipping an image with a
          # broken entrypoint or a shell in it is worse than shipping it
          # behaviourally untested.
          zot-image-structure = pkgs.callPackage ./tests/image-structure.nix { };

          # zot-image exercises the ARTEFACT end to end: load it into Docker,
          # start it with an externally supplied config and a mounted volume,
          # push, attach a referrer, restart, and confirm no shell is
          # reachable.
          #
          # Needs KVM: runNixOSTest is VM-based, and `containers.<name>` is
          # merged into `nodes` rather than being a systemd-nspawn mode. A
          # shared-vCPU cloud instance may not expose /dev/kvm at all, and an
          # argunix builder that cannot verify the device no longer advertises
          # the feature, so this check sits unscheduled rather than failing
          # fast. Uncomment once a builder with /dev/kvm is enrolled.
          #
          # Note that a red check does NOT hold back the push: argunix
          # publishes an image when its own job succeeds, and checks are
          # separate top-level jobs.
          #
          # zot-image = pkgs.testers.runNixOSTest ./tests/image.nix;
        };
      }
    );
}
