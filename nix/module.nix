{ self }:
{ config, lib, pkgs, ... }:
let cfg = config.services.sideband;
in {
  options.services.sideband = {
    enable = lib.mkEnableOption "sideband hub daemon";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.system}.default;
      description = "The sideband package providing the tg executable.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      description = ''
        User to run the hub as. Must be the same user the coding
        agents run as: they share the inbox spool on disk.
      '';
    };

    environmentFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        Env file with AGENT_TELEGRAM_BOT_TOKEN, AGENT_TELEGRAM_CHAT_ID,
        and optionally AGENT_TELEGRAM_GROUP_ID and WHISPER_URL.
      '';
    };

    stateDir = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Spool root. Defaults to the user's XDG state dir
        ($HOME/.local/state/sideband) when null.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.sideband = {
      description = "sideband Telegram hub daemon";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      environment = { TG_AGENT_ENV = toString cfg.environmentFile; }
        // lib.optionalAttrs (cfg.stateDir != null) {
          TG_STATE = toString cfg.stateDir;
        };
      serviceConfig = {
        ExecStart = "${cfg.package}/bin/tg daemon run";
        User = cfg.user;
        Restart = "always";
        RestartSec = 5;
      };
    };
  };
}
