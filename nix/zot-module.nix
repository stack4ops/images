# NixOS module for zot, an OCI-native registry.
#
# Exposed from this flake as `nixosModules.zot`. The package comes from
# `overlays.default`, so a consumer that applies the overlay needs no further
# wiring.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.zot;
  format = pkgs.formats.json { };

  # zot wants the port as a string, not a number. Getting this wrong produces
  # a config file zot rejects at startup with an unhelpful message.
  defaultSettings = {
    distSpecVersion = "1.1.1";

    storage = {
      rootDirectory = cfg.dataDir;

      # Inline garbage collection and layer deduplication. Both matter on a
      # host where disk is the binding constraint (concept paper 4.1).
      gc = true;
      gcDelay = "1h";
      gcInterval = "24h";
      dedupe = true;

      retention = {
        dryRun = false;
        delay = "24h";
        policies = [
          {
            repositories = [ "**" ];

            # MUST stay false. Referrers are how SBOMs and signatures are
            # attached to a manifest; deleting them would discard exactly the
            # artefacts this registry exists to serve.
            deleteReferrers = false;

            deleteUntagged = true;

            keepTags = [
              { patterns = [ "^latest$" ]; }
              {
                patterns = [ "^sha-[0-9a-f]+$" ];
                pulledWithin = "720h"; # 30 days
              }
            ];
          }
        ];
      };
    };

    http = {
      address = cfg.listenAddress;
      port = toString cfg.port;
    }
    // lib.optionalAttrs (cfg.htpasswdFile != null) {
      # systemd exposes LoadCredential= entries at a fixed path. NOT "%d/..."
      # -- unit specifiers are expanded in unit directives, never inside a
      # config file that some other program parses, so zot would look for a
      # directory literally named "%d".
      auth.htpasswd.path = "/run/credentials/zot.service/htpasswd";

      accessControl.repositories."**" = {
        # Anonymous pull, authenticated push. A registry serving build outputs
        # is meant to be readable; only the CI needs to write.
        anonymousPolicy = [ "read" ];
        policies = [
          {
            users = cfg.pushUsers;
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

    log.level = cfg.logLevel;
  };

  configFile = format.generate "zot-config.json" (
    lib.recursiveUpdate defaultSettings cfg.settings
  );
in
{
  options.services.zot = {
    enable = lib.mkEnableOption "the zot OCI registry";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.zot;
      defaultText = lib.literalExpression "pkgs.zot";
      description = "The zot package to run.";
    };

    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = ''
        Address to bind. Defaults to loopback on the assumption that a reverse
        proxy terminates TLS in front; zot itself is then never on the public
        interface.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 5000;
      description = "Port to bind.";
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/zot";
      description = ''
        Storage root. Served by systemd's StateDirectory, so a value outside
        /var/lib requires adjusting the unit as well.
      '';
    };

    htpasswdFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = "/var/lib/zot-credentials/htpasswd";
      description = ''
        Path to an htpasswd file granting push access. Passed to the unit via
        LoadCredential=, so systemd reads it as root and the file never needs
        to be readable by the service user.

        When null, zot runs without authentication -- acceptable only when
        nothing but loopback can reach it.
      '';
    };

    pushUsers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "argunix" ];
      description = ''
        Users from the htpasswd file granted write access. Has no effect
        unless htpasswdFile is set.
      '';
    };

    logLevel = lib.mkOption {
      type = lib.types.enum [
        "debug"
        "info"
        "warn"
        "error"
      ];
      default = "info";
      description = "zot log level.";
    };

    settings = lib.mkOption {
      inherit (format) type;
      default = { };
      description = ''
        Extra configuration, merged recursively over the defaults. Use this to
        enable extensions or override storage policy; anything set here wins.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.htpasswdFile != null -> cfg.pushUsers != [ ];
        message = ''
          services.zot.htpasswdFile is set but pushUsers is empty, so no
          account can push. Either list the htpasswd users that should have
          write access, or drop htpasswdFile.
        '';
      }
      {
        assertion = cfg.htpasswdFile != null || cfg.listenAddress == "127.0.0.1";
        message = ''
          services.zot listens on ${cfg.listenAddress} without authentication.
          Set htpasswdFile, or bind to 127.0.0.1 and put a reverse proxy in
          front.
        '';
      }
    ];

    systemd.services.zot = {
      description = "zot OCI registry";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        ExecStart = "${lib.getExe cfg.package} serve ${configFile}";
        Restart = "on-failure";
        RestartSec = "5s";

        DynamicUser = true;
        StateDirectory = "zot";
        StateDirectoryMode = "0700";

        LoadCredential = lib.optional (
          cfg.htpasswdFile != null
        ) "htpasswd:${cfg.htpasswdFile}";

        # A registry reads and writes its own state directory and talks HTTP.
        # It needs nothing else.
        AmbientCapabilities = lib.optional (cfg.port < 1024) "CAP_NET_BIND_SERVICE";
        CapabilityBoundingSet = lib.optional (cfg.port < 1024) "CAP_NET_BIND_SERVICE";
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHome = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectProc = "invisible";
        ProtectSystem = "strict";
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = [
          "@system-service"
          "~@privileged"
          "~@resources"
        ];
        LockPersonality = true;
        MemoryDenyWriteExecute = false; # Go runtime needs W^X exceptions
      };
    };
  };
}
