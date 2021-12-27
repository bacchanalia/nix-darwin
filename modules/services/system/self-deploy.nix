{ config, lib, pkgs, ... }:

let
  cfg = config.services.self-deploy;

  cmd =
    if builtins.isString cfg.input # in other words, a flake uri
    then darwinRebuild
    else script;

  darwinRebuild = lib.concatStringsSep " " [
    "${pkgs.nix-tools}/bin/darwin-rebuild"
    "--flake"
    cfg.input
    "--no-write-lock-file"
    "--recreate-lock-file"
    cfg.switchCommand
  ];

  script = pkgs.writeShellScript "self-deploy" ''
    set -e
    ${lib.optionalString (builtins.isString cfg.input.sshKeyFile)
      ''export GIT_SSH_COMMAND="${pkgs.openssh}/bin/ssh -i ${lib.escapeShellArg cfg.input.sshKeyFile}"''}
    export PATH=${pkgs.gnutar}/bin:${pkgs.gzip}/bin:$PATH

    if [ ! -e ${repositoryDirectory} ]; then
      mkdir -p ${repositoryDirectory}
      ${pkgs.gitMinimal}/bin/git init ${repositoryDirectory}
    fi

    ${gitWithRepo} fetch ${lib.escapeShellArg cfg.input.repository} ${lib.escapeShellArg cfg.input.branch}

    ${gitWithRepo} checkout FETCH_HEAD

    systemConfig="$(${config.nix.package}/bin/nix-build ${lib.cli.toGNUCommandLineShell { } {
      attr = cfg.input.nixAttribute;
      no-out-link = true;
    }} ${lib.escapeShellArg "${repositoryDirectory}${cfg.input.nixFile}"})"

    ${config.nix.package}/bin/nix-env --profile /nix/var/nix/profiles/system --set $systemConfig

    $systemConfig/activate-user

    $systemConfig/activate

    ${gitWithRepo} gc --prune=all
  '';

  workingDirectory = "/var/lib/nixos-self-deploy";
  repositoryDirectory = "${workingDirectory}/repo";
  gitWithRepo = "${pkgs.gitMinimal}/bin/git -C ${repositoryDirectory}";

  scriptOpts = {
    options = {
      repository = lib.mkOption {
        type = with lib.types; oneOf [ path str ];

        description = ''
          The repository to fetch from. Must be properly formatted for git.

          If this value is set to a path (must begin with `/`) then it's
          assumed that the repository is local and the resulting service
          won't wait for the network to be up.

          If the repository will be fetched over SSH, you must add an
          entry to `programs.ssh.knownHosts` for the SSH host for the fetch
          to be successful.
        '';
      };

      sshKeyFile = lib.mkOption {
        type = with lib.types; nullOr path;

        default = null;

        description = ''
          Path to SSH private key used to fetch private repositories over
          SSH.
        '';
      };

      branch = lib.mkOption {
        type = lib.types.str;

        default = "main";

        description = ''
          Branch to track

          Technically speaking any ref can be specified here, as this is
          passed directly to a `git fetch`, but for the use-case of
          continuous deployment you're likely to want to specify a branch.
        '';
      };

      nixAttribute = lib.mkOption {
        type = with lib.types; nullOr str;

        default = null;

        description = ''
          Attribute of `nixFile` that builds the current system.
        '';
      };

      nixFile = lib.mkOption {
        type = lib.types.path;

        default = "/default.nix";

        description = ''
          Path to nix file in repository. Leading '/' refers to root of
          git repository.
        '';
      };
    };
  };

in
{
  options.services.self-deploy = {
    enable = lib.mkEnableOption "self-deploy";

    input = lib.mkOption {
      type = lib.types.oneOf [ lib.types.str (lib.types.submodule scriptOpts) ];

      example = "github:example/foo/bar#baz.system";

      description = ''
        Either:
        1. Flake uri that builds this nix-darwin configuration given to the
           `--flake` option of `darwin-rebuild`.
        2. Options for building without a flake
      '';
    };

    logFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;

      default = null;

      example = "/var/log/self-deploy.log";

      description = "Path to the log file for `self-deploy`.";
    };

    failureHook = lib.mkOption {
      type = lib.types.nullOr lib.types.lines;
      default = null;
      description = ''
        Commands to run on failure.
      '';
    };

    switchCommand = lib.mkOption {
      type = lib.types.enum [ "boot" "switch" "dry-activate" "test" ];

      default = "switch";

      description = ''
        The `darwin-rebuild` subcommand used.
      '';
    };

    interval = lib.mkOption {
      type = lib.types.str;

      default = "0 * * * *";

      example = "59 23 * * *";

      description = ''
        The interval on which `darwin-rebuild` should be run, in
        vixie-cron notation.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Avoid launchdaemon unloading before activation is complete.
    services.cron.enable = true;
    services.cron.systemCronJobs =
      let
        log = lib.optionalString (cfg.logFile != null) "> ${cfg.logFile} 2>&1";

        script = pkgs.writeShellApplication {
          name = "self-deploy-cron-cmd";
          runtimeInputs = [ pkgs.coreutils ];
          text =  ''
            if ! (${cmd} ${log}); then
              ${lib.optionalString (cfg.failureHook != null)
                cfg.failureHook}
              exit
            fi
          '';
        };
      in
        [ "${cfg.interval} ${lib.getExe script}" ];
  };
}
