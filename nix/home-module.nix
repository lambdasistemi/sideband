{ self }:
{ config, lib, pkgs, ... }:
let
  cfg = config.services.sideband;
  package = self.packages.${pkgs.system}.default;
in {
  options.services.sideband = {
    enable = lib.mkEnableOption "sideband Telegram hub (systemd user service)";

    package = lib.mkOption {
      type = lib.types.package;
      default = package;
      defaultText = lib.literalExpression "sideband.packages.\${system}.default";
      description = "The sideband package providing the tg executable.";
    };

    environmentFile = lib.mkOption {
      type = lib.types.str;
      description = ''
        Path to the env file with AGENT_TELEGRAM_BOT_TOKEN,
        AGENT_TELEGRAM_CHAT_ID, and optionally AGENT_TELEGRAM_GROUP_ID and
        WHISPER_URL. Read at runtime, so it may live outside the Nix store.
      '';
      example = "%h/.config/sideband/env";
    };

    stateDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Spool root. Defaults to the user's XDG state dir
        ($HOME/.local/state/sideband) when null.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.package ];

    systemd.user.services.sideband = {
      Unit = {
        Description = "sideband Telegram hub daemon";
        After = [ "network-online.target" ];
        Wants = [ "network-online.target" ];
      };
      Service = {
        # tg reads the env file itself via TG_AGENT_ENV; EnvironmentFile is not
        # used so the file need not be a strict KEY=VALUE systemd env file.
        Environment = [ "TG_AGENT_ENV=${cfg.environmentFile}" ]
          ++ lib.optional (cfg.stateDir != null) "TG_STATE=${cfg.stateDir}";
        ExecStart = "${cfg.package}/bin/tg daemon run";
        Restart = "always";
        RestartSec = 5;
      };
      Install.WantedBy = [ "default.target" ];
    };
  };
}
