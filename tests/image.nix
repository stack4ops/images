# Behavioural integration test for the IMAGE, as opposed to the module.
#
# Boots a VM with Docker, loads the Nix-built zot image, and runs it the way an
# operator would: a mounted config, a mounted storage volume, a published port.
# Then pushes an artifact and attaches a referrer through the containerised
# registry.
#
# The split from tests/zot-referrers.nix is deliberate and the two do not
# overlap much:
#
#   zot-referrers.nix  -- the NixOS module: DynamicUser, LoadCredential-fed
#                         htpasswd, systemd hardening, StateDirectory. That
#                         needs a real NixOS system, so it defines the service
#                         directly on the test node.
#   image.nix (this)   -- the artifact we publish: does it load, does it start
#                         with an externally supplied config, does it serve.
#                         The node is only a Docker host; zot comes from the
#                         image, not from the node's configuration.
#
# Both need a VM: runNixOSTest is VM-based, and `containers.<name>` is merged
# into `nodes` rather than being a systemd-nspawn mode. Gated to x86_64-linux
# by the flake, because the framework needs KVM.
{ pkgs, ... }:
let
  pushUser = "argunix";
  pushPassword = "testsecret";

  htpasswd = pkgs.runCommand "zot-image-test-htpasswd" {
    nativeBuildInputs = [ pkgs.apacheHttpd ];
  } ''
    htpasswd -Bbc "$out" ${pushUser} ${pushPassword}
  '';

  # The image deliberately bakes in no config -- storage layout and auth belong
  # to the deployment. This is the file an operator would mount, and mounting
  # it is therefore part of what the test verifies.
  zotConfig = pkgs.writeText "config.json" (
    builtins.toJSON {
      distSpecVersion = "1.1.1";
      storage = {
        rootDirectory = "/var/lib/registry";
        gc = true;
        dedupe = false; # the container volume may not support hardlinks
      };
      http = {
        address = "0.0.0.0";
        port = "5000";
        auth.htpasswd.path = "/etc/zot/htpasswd";
        accessControl.repositories."**" = {
          anonymousPolicy = [ "read" ];
          policies = [
            {
              users = [ pushUser ];
              actions = [
                "read"
                "create"
                "update"
                "delete"
              ];
            }
          ];
        };
      };
      log.level = "info";
    }
  );
in
{
  name = "zot-image";

  globalTimeout = 5 * 60;

  nodes.machine = {
    virtualisation.docker.enable = true;

    environment.systemPackages = [
      pkgs.oras
      pkgs.jq
      pkgs.curl
    ];

    networking.dhcpcd.enable = false;
  };

  testScript = ''
    machine.wait_for_unit("docker.service")

    with subtest("the Nix-built image loads into Docker"):
        machine.succeed("docker load --input ${pkgs.ociImages.zot}")
        # The tag comes from name/tag inside buildImage, which is internal to
        # the archive -- unlike the registry path, which argunix derives from
        # the flake attribute name.
        machine.succeed("docker image inspect zot:latest > /dev/null")

    with subtest("the container starts with an externally supplied config"):
        machine.succeed(
            "docker run -d --name registry -p 5000:5000 "
            "-v ${zotConfig}:/etc/zot/config.json:ro "
            "-v ${htpasswd}:/etc/zot/htpasswd:ro "
            "-v zot-storage:/var/lib/registry "
            "zot:latest"
        )
        machine.wait_until_succeeds(
            "curl -fsS http://localhost:5000/v2/ -o /dev/null", timeout=60
        )

    with subtest("the entrypoint really is zot, not a shell that exited"):
        out = machine.succeed("docker inspect -f '{{.State.Running}}' registry")
        assert out.strip() == "true", f"container not running: {out!r}"

    with subtest("anonymous push is rejected, authenticated push succeeds"):
        machine.succeed("echo hello > /tmp/payload.txt")
        machine.fail(
            "cd /tmp && oras push --plain-http localhost:5000/test:v1 payload.txt"
        )
        machine.succeed(
            "cd /tmp && oras push --plain-http "
            "-u ${pushUser} -p ${pushPassword} "
            "localhost:5000/test:v1 payload.txt"
        )

    with subtest("referrers work through the containerised registry too"):
        machine.succeed("echo '{\"sbom\":true}' > /tmp/sbom.json")
        machine.succeed(
            "cd /tmp && oras attach --plain-http "
            "-u ${pushUser} -p ${pushPassword} "
            "--artifact-type application/vnd.test.sbom "
            "localhost:5000/test:v1 sbom.json"
        )
        digest = machine.succeed(
            "oras manifest fetch --plain-http --descriptor "
            "localhost:5000/test:v1 | jq -r .digest"
        ).strip()
        refs = machine.succeed(
            f"curl -fsS http://localhost:5000/v2/test/referrers/{digest}"
        )
        assert "vnd.test.sbom" in refs, f"no referrer returned: {refs!r}"

    with subtest("data survives a container restart on the mounted volume"):
        machine.succeed("docker restart registry")
        machine.wait_until_succeeds(
            "curl -fsS http://localhost:5000/v2/ -o /dev/null", timeout=60
        )
        machine.succeed(
            "oras manifest fetch --plain-http localhost:5000/test:v1 -o /dev/null"
        )

    with subtest("the image carries the CA bundle its config points at"):
        # SSL_CERT_FILE is set in the image config; without the file behind it,
        # outbound TLS from the container fails at runtime with an error that
        # points nowhere useful.
        env = machine.succeed(
            "docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' zot:latest"
        )
        cert_path = next(
            line.split("=", 1)[1]
            for line in env.splitlines()
            if line.startswith("SSL_CERT_FILE=")
        )

        # Probed from the outside on purpose: the image ships no shell, so
        # `docker run --entrypoint /bin/sh` is not available. `docker create`
        # makes the filesystem reachable without starting anything.
        machine.succeed("docker create --name probe zot:latest")
        machine.succeed(f"docker cp probe:{cert_path} /tmp/ca-bundle.crt")
        machine.succeed("test -s /tmp/ca-bundle.crt")

    with subtest("the image ships no shell"):
        # Not incidental: /bin holds the zot binary and nothing else, so a
        # command-injection foothold has no interpreter to build on. Pinned
        # here because a careless `copyToRoot` addition would silently undo it.
        machine.fail("docker cp probe:/bin/sh /tmp/sh")
        machine.fail("docker cp probe:/bin/bash /tmp/bash")
        machine.succeed("docker rm probe")
  '';
}
