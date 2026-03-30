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

    # Systemd user service (NixOS / Linux)
    systemd.user.services.skillrunner = lib.mkIf isLinux {
      Unit = {
        Description = "SkillRunner — scheduled Claude Code skill executor";
      };
      Service = {
        Type = "oneshot";
        ExecStart = "${package}/bin/skillrunner-daemon";
        Nice = 10;
        Environment = let
          profilePaths = lib.concatStringsSep ":" [
            "${config.home.profileDirectory}/bin"
            "/etc/profiles/per-user/${config.home.username}/bin"
            "/run/current-system/sw/bin"
            "/run/wrappers/bin"
          ];
        in [ "PATH=${profilePaths}" ];
      };
    };

    systemd.user.timers.skillrunner = lib.mkIf isLinux {
      Unit = {
        Description = "SkillRunner wake timer";
      };
      Timer = {
        OnActiveSec = "1min";
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
