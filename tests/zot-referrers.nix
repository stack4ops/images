# Behavioural integration test: boot a VM running zot from the NixOS module,
# push an artifact, attach a referrer to it, and assert the referrer is
# discoverable BOTH through oras and through the native Referrers API endpoint.
#
# The second assertion is the one that carries weight. `oras discover` also
# succeeds against an OCI 1.0 registry, because oras falls back to the
# Referrers Tag Schema when the endpoint 404s. Only the direct call to
# /v2/<name>/referrers/<digest> distinguishes a genuine OCI 1.1 implementation
# from that fallback — and knowing which one is in front of you is the entire
# reason this registry exists (ADR-006).
#
# Also pins the module's access-control defaults: anonymous pull, authenticated
# push. That policy is easy to break silently while editing storage settings.
#
# Gated to x86_64-linux by the flake (the test framework needs KVM).
{ pkgs, ... }:
let
  pushUser = "argunix";
  pushPassword = "testsecret";

  # Generated at build time rather than checked in: a bcrypt hash with a fixed
  # salt would be a credential-shaped constant in the repo, and there is no
  # reason to have one.
  htpasswd = pkgs.runCommand "zot-test-htpasswd" { nativeBuildInputs = [ pkgs.apacheHttpd ]; } ''
    htpasswd -Bbc "$out" ${pushUser} ${pushPassword}
  '';
in
{
  name = "zot-referrers";

  globalTimeout = 5 * 60;

  nodes.machine =
    { ... }:
    {
      imports = [ ../nix/zot-module.nix ];

      services.zot = {
        enable = true;
        listenAddress = "127.0.0.1";
        port = 5000;
        htpasswdFile = htpasswd;
        pushUsers = [ pushUser ];
      };

      environment.systemPackages = [
        pkgs.oras
        pkgs.jq
        pkgs.curl
      ];

      networking.dhcpcd.enable = false;
    };

  testScript = ''
    machine.wait_for_unit("zot.service")
    machine.wait_for_open_port(5000)

    with subtest("the registry answers the OCI base endpoint"):
        machine.succeed("curl -fsS http://127.0.0.1:5000/v2/ -o /dev/null")

    with subtest("anonymous push is rejected"):
        machine.succeed("echo hello > /tmp/payload.txt")
        machine.fail(
            "cd /tmp && oras push --plain-http "
            "127.0.0.1:5000/test:v1 payload.txt"
        )

    with subtest("authenticated push succeeds"):
        machine.succeed(
            "cd /tmp && oras push --plain-http "
            "-u ${pushUser} -p ${pushPassword} "
            "127.0.0.1:5000/test:v1 payload.txt"
        )

    with subtest("anonymous pull is allowed"):
        machine.succeed(
            "cd /tmp && oras manifest fetch --plain-http "
            "127.0.0.1:5000/test:v1 -o /dev/null"
        )

    with subtest("attach a referrer to the pushed manifest"):
        machine.succeed("echo '{\"sbom\":true}' > /tmp/sbom.json")
        machine.succeed(
            "cd /tmp && oras attach --plain-http "
            "-u ${pushUser} -p ${pushPassword} "
            "--artifact-type application/vnd.test.sbom "
            "127.0.0.1:5000/test:v1 sbom.json"
        )

    with subtest("oras discovers the referrer"):
        out = machine.succeed(
            "oras discover --plain-http 127.0.0.1:5000/test:v1"
        )
        assert "vnd.test.sbom" in out, f"referrer not discoverable: {out!r}"

    with subtest("the native Referrers API serves it"):
        # An OCI 1.0 registry would 404 here and still have passed the
        # subtest above, via the Referrers Tag Schema fallback.
        digest = machine.succeed(
            "oras manifest fetch --plain-http --descriptor "
            "127.0.0.1:5000/test:v1 | jq -r .digest"
        ).strip()
        refs = machine.succeed(
            f"curl -fsS http://127.0.0.1:5000/v2/test/referrers/{digest}"
        )
        assert "vnd.test.sbom" in refs, (
            f"native referrers API did not return the referrer: {refs!r}"
        )

    with subtest("storage lives where the module says it does"):
        machine.succeed("test -d /var/lib/zot/test")
        # Hardlink-backed dedupe is one reason zot is affordable on a
        # disk-constrained host; a filesystem without it disables the feature
        # silently, with only a warning at startup.
        machine.fail("journalctl -u zot.service | grep -q 'disabling dedupe'")
  '';
}
