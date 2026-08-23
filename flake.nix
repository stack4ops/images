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

      inherit (inputs.nixpkgs) lib;
    in
    {
      # Not per-system, so outside eachSystem. Consumers who want `pkgs.zot`
      # -- which is what the NixOS module's `package` option defaults to --
      # add this overlay.
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
        # as `zot` lands at <registry>/<namespace>/zot. Images therefore take
        # the plain names, and the binary gets a suffixed one so the two do
        # not collide when the sets are merged.
        #
        # argunix builds EVERY attribute and pushes only those carrying
        # meta.image-format, so exposing the binary costs nothing at the
        # registry -- and buys a separate job, which keeps a Go compile
        # failure distinguishable from an image assembly failure. That
        # distinction is worth having once aarch64 builds run under binfmt
        # emulation.
        packages = pkgs.ociImages // {
          zot-bin = pkgs.zot;

          # NOT an image: aliasing pkgs.ociImages.zot here would inherit its
          # meta.image-format and get pushed a second time as "default".
          default = pkgs.zot;
        };

        apps.default = {
          type = "app";
          program = lib.getExe pkgs.zot;
          meta.description = "Run the zot registry";
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
            # `crane` is not an attribute in nixpkgs -- the binary ships in
            # go-containerregistry, which declares it as mainProgram.
            pkgs.go-containerregistry
            # htpasswd, for generating the push credentials the module wants.
            pkgs.apacheHttpd
          ];
        };
      }
    #   // lib.optionalAttrs (system == "x86_64-linux") {
    #     # Two behavioural tests, deliberately not merged:
    #     #
    #     #   zot-referrers -- the NixOS module: DynamicUser, LoadCredential-fed
    #     #                    htpasswd, systemd hardening, StateDirectory.
    #     #   zot-image     -- the artifact we publish: does it load into
    #     #                    Docker, start with a mounted config, serve, and
    #     #                    still ship no shell.
    #     #
    #     # Both need KVM: runNixOSTest is VM-based, and `containers.<name>` is
    #     # merged into `nodes` rather than being a systemd-nspawn mode. A
    #     # shared-vCPU cloud instance may not expose /dev/kvm at all -- check
    #     # before expecting these to run on the CI box.
    #     #
    #     # Note that a red check does NOT hold back the push: argunix
    #     # publishes an image when its own job succeeds, and checks are
    #     # separate top-level jobs.
    #     checks = {
    #       zot-referrers = pkgs.testers.runNixOSTest ./tests/zot-referrers.nix;
    #       zot-image = pkgs.testers.runNixOSTest ./tests/image.nix;
    #     };
    #   }
    # );
}
