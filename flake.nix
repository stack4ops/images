{
  description = "zot OCI registry: package, NixOS module, and OCI images (argunix-compatible)";

  inputs = {
    # Pinned to the release the consuming host tracks. Following unstable here
    # would drag a second nixpkgs instance -- and a second Go toolchain and
    # cacert -- into any system that imports this flake.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  };

  outputs =
    inputs:
    let
      # Explicit and Linux-only. flake-utils' eachDefaultSystem would add the
      # two darwin systems, where dockerTools cannot build an image at all.
      # aarch64-linux is listed so the per-arch outputs exist for argunix to
      # assemble into a multi-arch index -- which also needs `aarch64-linux`
      # in services.argunix.systems and a builder for it (native, or the
      # coordinator with boot.binfmt.emulatedSystems).
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      eachSystem =
        systems: f:
        builtins.foldl' (
          a: s: a // builtins.mapAttrs (k: v: (a.${k} or { }) // { ${s} = v; }) (f s)
        ) { } systems;

      inherit (inputs.nixpkgs) lib;
    in
    {
      # Not per-system, so outside eachSystem. Consumers who want `pkgs.zot`
      # -- which is what the NixOS module defaults to -- add this overlay.
      overlays.default = import ./overlay.nix;

      nixosModules.zot = ./nix/zot-module.nix;
      nixosModules.default = inputs.self.nixosModules.zot;
    }
    // eachSystem systems (
      system:
      let
        pkgs = import inputs.nixpkgs {
          inherit system;
          overlays = [ inputs.self.overlays.default ];
        };
      in
      {
        # Attribute names here become registry image names: an image exposed
        # as `zot` lands at <registry>/<namespace>/zot. The images therefore
        # take the plain names, and the binary is exposed under a suffixed one
        # so the two do not collide when the sets are merged.
        packages = pkgs.ociImages // {
          # NOT `zot`: that name belongs to the image above, and `//` would
          # let the binary silently replace it.
          zot-bin = pkgs.zot;

          default = pkgs.ociImages.zot;
        };

        apps.default = {
          type = "app";
          program = lib.getExe pkgs.zot;
        };

        devShells.default = pkgs.mkShell {
          packages = [
            pkgs.zot
            pkgs.regctl
            # oras is the tool for the referrers work this registry exists to
            # exercise: `oras discover` lists artifacts attached to a
            # manifest, `oras pull` fetches one. regctl alone does not cover
            # it.
            pkgs.oras
            pkgs.skopeo
            pkgs.crane
            # htpasswd, for generating the push credentials the module wants.
            pkgs.apacheHttpd
          ];
        };
      }
      # // lib.optionalAttrs (system == "x86_64-linux") {
      #   # NixOS-VM behavioural test: boots a VM running zot from the module in
      #   # this flake, pushes an artifact, attaches a referrer and asserts it is
      #   # served by the native Referrers API -- not merely by the Referrers Tag
      #   # Schema fallback an OCI 1.0 registry would also pass.
      #   #
      #   # Gated to x86_64-linux because the test framework needs KVM. A shared
      #   # vCPU cloud instance may not expose /dev/kvm at all; check before
      #   # expecting this to run on the CI box.
      #   checks.zot-referrers = pkgs.testers.runNixOSTest ./tests/zot-referrers.nix;
      # }
    );
}
