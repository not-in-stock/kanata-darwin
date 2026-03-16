{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.kanata;
  user = cfg.user;
  userHome = "/Users/${user}";
  useTccHack = cfg.daemon.enable && !cfg.sudoers;
in

{
  options.services.kanata.daemon = {
    enable = lib.mkEnableOption "headless kanata launchd service";
    extraLaunchdConfig = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = ''
        Extra launchd plist keys (e.g. KeepAlive, ThrottleInterval).
        Shallow-merged (nested keys are replaced, not deep-merged).
      '';
    };
  };

  config = lib.mkIf (cfg.enable && cfg.daemon.enable) {
    warnings = lib.optional useTccHack ''
      services.kanata: running in daemon mode with sudoers=false uses a fragile TCC sqlite3 hack
      to grant Input Monitoring permission. Apple may change the TCC.db schema in future macOS
      updates, which would silently break kanata — or worse, corrupt the TCC database.
      Consider using sudoers=true (default) or kanata-bar/kanata-tray instead.
    '';

    system.activationScripts.postActivation.text = lib.mkAfter (
      lib.optionalString useTccHack ''
        # Grant kanata Input Monitoring (kTCCServiceListenEvent) permission via TCC sqlite3 hack.
        KANATA_BIN="${cfg.package}/bin/kanata"
        if [ -x "$KANATA_BIN" ]; then
          CDHASH=$(codesign -dvvv "$KANATA_BIN" 2>&1 | grep "CDHash=" | head -1 | cut -d= -f2)
          if [ -n "$CDHASH" ]; then
            CSREQ_HEX="FADE0C0000000028000000010000000800000014$(echo "$CDHASH" | tr '[:lower:]' '[:upper:]')"
            /usr/bin/sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" "
              DELETE FROM access WHERE service='kTCCServiceListenEvent' AND client LIKE '%/kanata';
              INSERT INTO access (service, client, client_type, auth_value, auth_reason, auth_version, csreq, flags, indirect_object_identifier)
              VALUES ('kTCCServiceListenEvent', '$KANATA_BIN', 1, 2, 4, 1, X'$CSREQ_HEX', 0, 'UNUSED');
            "
            echo "kanata: updated Input Monitoring TCC entry for $KANATA_BIN"
          fi
        fi

        # Restart kanata to pick up updated TCC entry.
        launchctl kickstart -k system/org.kanata.daemon &>/dev/null &
      ''
    );

    # daemon + sudoers=false: root launchd daemon (requires TCC hack)
    launchd.daemons.kanata = lib.mkIf useTccHack {
      serviceConfig =
        {
          Label = "org.kanata.daemon";
          ProgramArguments = [
            "${cfg.package}/bin/kanata"
            "--cfg"
            cfg.configFile
            "--nodelay"
          ];
          RunAtLoad = false;
          KeepAlive = {
            PathState = {
              "/Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice" = true;
            };
          };
          StandardOutPath = "/tmp/kanata.log";
          StandardErrorPath = "/tmp/kanata.err";
          SessionCreate = true;
          ThrottleInterval = 3;
        }
        // cfg.daemon.extraLaunchdConfig;
    };

    # daemon + sudoers=true: user agent via sudo NOPASSWD (no TCC hack)
    launchd.user.agents.kanata = lib.mkIf cfg.sudoers {
      serviceConfig =
        {
          Label = "org.kanata.daemon";
          ProgramArguments = [
            "/usr/bin/sudo"
            "${cfg.package}/bin/kanata"
            "--cfg"
            cfg.configFile
            "--nodelay"
          ];
          RunAtLoad = true;
          KeepAlive = true;
          StandardOutPath = "/tmp/kanata.log";
          StandardErrorPath = "/tmp/kanata.err";
          ThrottleInterval = 3;
        }
        // cfg.daemon.extraLaunchdConfig;
    };
  };
}
