{ config, lib, pkgs, ... }:

let

  inherit (lib)
    literalExpression
    mkDefault
    mkIf
    mkMerge
    mkOption
    optional
    optionalString
    types
    ;

  # Put all the system cronjobs together.
  systemCronJobsFile = pkgs.writeText "system-crontab"
    ''
      SHELL=${pkgs.bash}/bin/bash
      PATH=${config.system.path}/bin:${config.system.path}/sbin
      ${optionalString (config.services.cron.mailto != null) ''
        MAILTO="${config.services.cron.mailto}"
      ''}
      NIX_CONF_DIR=/etc/nix
      ${lib.concatStrings (map (job: job + "\n") config.services.cron.systemCronJobs)}
    '';

  allFiles =
    optional (config.services.cron.systemCronJobs != [ ]) systemCronJobsFile;

  crontabs = pkgs.runCommand "crontabs" { inherit allFiles; preferLocalBuild = true; }
    ''
      touch $out
      for i in $allFiles; do
        cat "$i" >> $out
      done
    '';

in

{

  ###### interface

  options = {

    services.cron = {

      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Whether to enable the Vixie cron daemon.";
      };

      mailto = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Email address to which job output will be mailed.";
      };

      systemCronJobs = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = literalExpression ''
          [ "* * * * *  test   ls -l / > /tmp/cronout 2>&1"
            "* * * * *  eelco  echo Hello World > /home/eelco/cronout"
          ]
        '';
        description = ''
          A list of Cron jobs to be appended to the system-wide
          crontab.  See the manual page for crontab for the expected
          format. If you want to get the results mailed you must setuid
          sendmail. See <option>security.wrappers</option>

          If neither /var/cron/cron.deny nor /var/cron/cron.allow exist only root
          is allowed to have its own crontab file. The /var/cron/cron.deny file
          is created automatically for you, so every user can use a crontab.

          Many nixos modules set systemCronJobs, so if you decide to disable vixie cron
          and enable another cron daemon, you may want it to get its system crontab
          based on systemCronJobs.
        '';
      };
    };
  };


  ###### implementation

  config = mkMerge [

    {
      services.cron.enable = mkDefault (allFiles != [ ]);
      system.activationScripts.system-crontabs.text = mkDefault ''
        echo 'reloading system crontabs'
      '';
    }
    (mkIf config.services.cron.enable {
      system.activationScripts.system-crontabs.text = ''
        cat ${crontabs} | crontab -u root -
      '';
    })
  ];
}
