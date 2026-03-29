skillrunner: { config, lib, pkgs, ... }:

let
  cfg = config.services.skillrunner;
  package = skillrunner.packages.${pkgs.system}.default;
  isLinux = pkgs.stdenv.isLinux;
  isDarwin = pkgs.stdenv.isDarwin;
in {
  options.services.skillrunner = {
    enable = lib.mkEnableOption "SkillRunner daemon for scheduled Claude Code skills";
  };

  config = lib.mkIf cfg.enable {

    home.packages = [ package ];

    # Symlink skills into Claude Code's skill directory
    home.file.".claude/skills/schedule/SKILL.md".source =
      "${package}/share/skillrunner/SKILL.md";
    home.file.".claude/skills/schedule-setup/SKILL.md".source =
      "${package}/share/skillrunner/SETUP_SKILL.md";

    # Create runtime directories via activation script
    home.activation.skillrunner-dirs = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      mkdir -p "${config.home.homeDirectory}/.config/skillrunner"/{logs/output,locks}
      if [ ! -f "${config.home.homeDirectory}/.config/skillrunner/config.json" ]; then
        echo '{"version": 1, "projects": [], "schedules": []}' > \
          "${config.home.homeDirectory}/.config/skillrunner/config.json"
      fi
      echo '{"last_wake": null, "pid": null, "version": 1}' > \
        "${config.home.homeDirectory}/.config/skillrunner/state.json"
      # Create secrets file (for Telegram token) if it doesn't exist
      if [ ! -f "${config.home.homeDirectory}/.config/skillrunner/secrets.env" ]; then
        echo '# Add your Telegram bot token here:' > \
          "${config.home.homeDirectory}/.config/skillrunner/secrets.env"
        echo '# SKILLRUNNER_TELEGRAM_TOKEN=your_bot_token_here' >> \
          "${config.home.homeDirectory}/.config/skillrunner/secrets.env"
        chmod 600 "${config.home.homeDirectory}/.config/skillrunner/secrets.env"
      fi
    '';

    # Systemd user service (NixOS / Linux)
    systemd.user.services.skillrunner = lib.mkIf isLinux {
      Unit = {
        Description = "SkillRunner — scheduled Claude Code skill executor";
      };
      Service = {
        Type = "oneshot";
        ExecStart = "${package}/bin/skillrunner-daemon";
        Nice = 10;
      };
    };

    systemd.user.timers.skillrunner = lib.mkIf isLinux {
      Unit = {
        Description = "SkillRunner wake timer";
      };
      Timer = {
        OnBootSec = "1min";
        OnUnitActiveSec = "1min";
        Persistent = true;   # catch up after sleep/reboot
      };
      Install = {
        WantedBy = [ "timers.target" ];
      };
    };

    # macOS LaunchAgent
    launchd.agents.skillrunner = lib.mkIf isDarwin {
      enable = true;
      config = {
        Label = "com.skillrunner.daemon";
        ProgramArguments = [ "${package}/bin/skillrunner-daemon" ];
        StartInterval = 60;
        RunAtLoad = true;
        StandardOutPath =
          "${config.home.homeDirectory}/.config/skillrunner/logs/launchd-stdout.log";
        StandardErrorPath =
          "${config.home.homeDirectory}/.config/skillrunner/logs/launchd-stderr.log";
        Nice = 10;
        ProcessType = "Background";
      };
    };
  };
}
