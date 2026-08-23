# The zot binary itself. Kept as a top-level overlay attribute so both the
# image and any NixOS consumer reuse the identical derivation.
{
  lib,
  buildGoModule,
  fetchFromGitHub,
}:

buildGoModule rec {
  pname = "zot";
  version = "2.1.17";

  src = fetchFromGitHub {
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
  # For the full flavour:
  # tags = [ "sync" "search" "scrub" "metrics" "lint" "ui" "mgmt" "imagetrust" "events" ];

  ldflags = [
    "-s"
    "-w"
    "-X github.com/project-zot/zot/pkg/api/config.ReleaseTag=v${version}"
  ];

  meta = {
    description = "OCI-native container image registry";
    homepage = "https://zotregistry.dev";
    license = lib.licenses.asl20;
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
    mainProgram = "zot";
  };
}
