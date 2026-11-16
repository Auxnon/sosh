# sosh on NixOS: the server image (ghcr.io/auxnon/sosh, built by
# .github/workflows/image.yml) and Postgres 17, as two podman containers on
# their own network. The server is published on 127.0.0.1 only; a reverse
# proxy (site-delta, for sosh.makeavoy.com) puts it on the internet.
#
#   imports = [ ./path/to/sosh/deploy/nixos/sosh.nix ];   # or the flake's nixosModules.default
#   services.sosh = {
#     enable = true;
#     environmentFile = "/var/lib/sosh/env";   # secrets, see deploy/README.md
#   };
{ config, lib, pkgs, ... }:

let
  cfg = config.services.sosh;
  podman = "${config.virtualisation.podman.package}/bin/podman";
  autoUpdate = lib.optionals cfg.autoUpdate [
    "--label=io.containers.autoupdate=registry"
  ];
  # an image only this machine has: deployed by sosh-deploy, never pulled
  local = lib.hasPrefix "localhost/" cfg.image;
  # `sosh-deploy release|build|load|rollback|status` (deploy/sosh-deploy)
  deploy = pkgs.writeShellScriptBin "sosh-deploy" ''
    [ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"
    export SOSH_IMAGE=${lib.escapeShellArg cfg.image}
    export SOSH_RELEASES=${lib.escapeShellArg cfg.releases}
    export SOSH_SRC=${lib.escapeShellArg (toString cfg.source)}
    export SOSH_DATA=${lib.escapeShellArg (toString cfg.dataDir)}
    export SOSH_PORT=${toString cfg.port}
    export PATH=${lib.makeBinPath [ config.virtualisation.podman.package pkgs.git pkgs.curl pkgs.gzip pkgs.coreutils pkgs.gnused pkgs.gnugrep pkgs.findutils config.systemd.package ]}:$PATH
    exec ${pkgs.bash}/bin/bash ${../sosh-deploy} "$@"
  '';
in
{
  options.services.sosh = {
    enable = lib.mkEnableOption "the sosh server";

    image = lib.mkOption {
      type = lib.types.str;
      default = "localhost/sosh:live";
      description = ''
        The image the service runs. The default is a local tag that
        `sosh-deploy` moves (a release, a build here, or one loaded from
        elsewhere); on first start it's seeded from `releases`:latest.
        A registry image instead (say "ghcr.io/auxnon/sosh:latest", with
        `autoUpdate`) is pulled when newer on every restart, and
        `sosh-deploy` can't be used.
      '';
    };

    releases = lib.mkOption {
      type = lib.types.str;
      default = "ghcr.io/auxnon/sosh";
      description = "Where release images are (.github/workflows/release.yml pushes them for each v* tag), for `sosh-deploy release`.";
    };

    source = lib.mkOption {
      type = lib.types.str;
      default = "/srv/sosh";
      description = "A git checkout of sosh, for `sosh-deploy build`.";
    };

    postgresImage = lib.mkOption {
      type = lib.types.str;
      default = "docker.io/library/postgres:17";
      description = "Postgres image. Its data lives in `dataDir`; a major version change needs a dump and restore.";
    };

    host = lib.mkOption {
      type = lib.types.str;
      default = "sosh.makeavoy.com";
      description = "The public host name (PHX_HOST): links, websocket origin checks, the mail sender.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 4000;
      description = "Port on 127.0.0.1 the server is published on, for the reverse proxy.";
    };

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/sosh";
      description = "Where Postgres keeps its data (`dataDir`/postgres).";
    };

    environmentFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        Secrets, as KEY=value lines, kept out of the Nix store:
        SECRET_KEY_BASE and POSTGRES_PASSWORD (required), and for email
        SMTP_HOST, SMTP_PORT, SMTP_USERNAME, SMTP_PASSWORD, MAIL_FROM.
        Without SMTP_HOST, emails (and their codes) only go to the journal.
      '';
    };

    environment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "More environment for the server (POOL_SIZE, MAIL_FROM_NAME, ...).";
    };

    autoUpdate = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Pull a newer `image` and restart daily (podman-auto-update.timer), so each release (a v* tag) deploys itself.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [{
      assertion = !(cfg.autoUpdate && local);
      message = "services.sosh.autoUpdate needs a registry image (services.sosh.image = \"ghcr.io/auxnon/sosh:latest\"); with a local one, deploy with sosh-deploy";
    }];

    environment.systemPackages = [ deploy ];

    virtualisation.podman.enable = true;
    virtualisation.oci-containers.backend = "podman";

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0750 root root -"
      "d ${cfg.dataDir}/postgres 0700 root root -"
    ];

    # The containers' network: the server reaches Postgres as `sosh-db`.
    systemd.services.sosh-network = {
      description = "podman network for sosh";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = "${podman} network exists sosh || ${podman} network create sosh";
    };

    virtualisation.oci-containers.containers = {
      sosh-db = {
        image = cfg.postgresImage;
        environment = {
          POSTGRES_USER = "sosh";
          POSTGRES_DB = "sosh";
        };
        environmentFiles = [ cfg.environmentFile ];
        volumes = [ "${cfg.dataDir}/postgres:/var/lib/postgresql/data" ];
        extraOptions = [ "--network=sosh" "--network-alias=sosh-db" ];
      };

      sosh = {
        image = cfg.image;
        dependsOn = [ "sosh-db" ];
        ports = [ "127.0.0.1:${toString cfg.port}:4000" ];
        environment = {
          PHX_HOST = cfg.host;
          DB_HOST = "sosh-db";
          DB_USER = "sosh";
          DB_NAME = "sosh";
          # Only the proxy can reach it (127.0.0.1), so take the client
          # address it passes on for rate limits.
          TRUST_PROXY = "1";
        } // cfg.environment;
        environmentFiles = [ cfg.environmentFile ];
        # a registry image: check for a newer one on every (re)start
        pull = if local then "never" else "newer";
        extraOptions = [ "--network=sosh" ]
          ++ autoUpdate ++ [ "--label=PODMAN_SYSTEMD_UNIT=podman-sosh.service" ];
      };
    };

    systemd.services.podman-sosh-db = {
      requires = [ "sosh-network.service" ];
      after = [ "sosh-network.service" ];
    };
    systemd.services.podman-sosh = {
      requires = [ "sosh-network.service" ];
      after = [ "sosh-network.service" "network-online.target" ];
      wants = [ "network-online.target" ];
      # the first start of a local image: the newest release, until
      # sosh-deploy puts something else there
      preStart = lib.mkIf local (lib.mkBefore ''
        if ! ${podman} image exists ${lib.escapeShellArg cfg.image}; then
          ${podman} pull ${lib.escapeShellArg "${cfg.releases}:latest"} \
            && ${podman} tag ${lib.escapeShellArg "${cfg.releases}:latest"} ${lib.escapeShellArg cfg.image}
        fi
      '');
    };

    systemd.timers.podman-auto-update = lib.mkIf cfg.autoUpdate {
      wantedBy = [ "timers.target" ];
    };
  };
}
