# The zot binary itself. Kept as a top-level overlay attribute so both the
# image and any NixOS consumer reuse the identical derivation.
{
  lib,
  buildGoModule,
  fetchFromGitHub,
  go,
  versionCheckHook,
}:

buildGoModule rec {
  pname = "zot";
  # renovate: datasource=github-releases depName=project-zot/zot
  version = "2.1.17";

  src = fetchFromGitHub {
    # Version in the name, so a version bump with a stale hash fails
    # instead of silently reusing the old source from the store.
    name = "zot-${version}-source";
    owner = "project-zot";
    repo = "zot";
    rev = "v${version}";
    hash = "sha256-/1QEMpDq8okaVWhaynlJ+tE1b6AObUnHfHrmnylBKL0=";
  };

  vendorHash = "sha256-09LQKBKyqpgBbC44VPsZ3RJcwrHWy6TpF87u35UgcYI=";

  subPackages = [ "cmd/zot" ];

  # Minimal build: the core registry as defined by the OCI Distribution
  # Specification, without extensions. The Referrers API is part of that core,
  # so SBOM and signature discovery works here -- the extensions add the web
  # UI, GraphQL search, CVE scanning and friends, none of which this
  # deployment needs.
  #
  # For the full flavour (also set BinaryType below to something other than
  # "minimal"):
  # tags = [ "sync" "search" "scrub" "metrics" "lint" "ui" "mgmt" "imagetrust" "events" ];

  # Build info, mirroring upstream's Makefile (binary-minimal target). The
  # module path is zotregistry.dev/zot/v2 and the variables live in
  # pkg/buildinfo.
  #
  # `zot --version` prints Commit, BinaryType and GoVersion -- NOT ReleaseTag.
  # Upstream fills Commit from `git describe --tags`, so it starts with the
  # release tag; with no git checkout here, the tag itself is the closest
  # equivalent and is what puts the version into the output.
  #
  # A -X flag naming a package that does not exist is silently ignored by the
  # Go linker. The version check below is what catches that now.
  ldflags =
    let
      buildinfo = "zotregistry.dev/zot/v2/pkg/buildinfo";
    in
    [
      "-s"
      "-w"
      "-X ${buildinfo}.ReleaseTag=v${version}"
      "-X ${buildinfo}.Commit=v${version}"
      "-X ${buildinfo}.BinaryType=minimal"
      "-X ${buildinfo}.GoVersion=go${go.version}"
    ];

  # Runs `zot --version` on the installed binary and fails the build unless
  # the output contains `version`. Part of the package itself rather than a
  # separate check on purpose: argunix pushes an image when its own job
  # succeeds and does not wait for checks, but the image cannot build without
  # this derivation -- so a binary with broken build info never reaches the
  # registry. Needs no KVM.
  nativeInstallCheckInputs = [ versionCheckHook ];
  doInstallCheck = true;
  versionCheckProgramArg = "--version";

  meta = {
    description = "OCI-native container image registry";
    homepage = "https://zotregistry.dev";
    license = lib.licenses.asl20;
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
    mainProgram = "zot";
  };
}
