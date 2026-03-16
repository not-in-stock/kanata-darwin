{ kanata-tray, darwin-smapp }:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.kanata;

  karabiner-driver-pkg = pkgs.fetchurl {
    url = "https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice/releases/download/v6.10.0/Karabiner-DriverKit-VirtualHIDDevice-6.10.0.pkg";
    hash = "sha256-4TF9f+aK0tVZz0EBjCvGcJ4XjRO9tfhe4w896vSBeWY=";
  };
  karabiner-driver-version = "6.10.0";

  user = cfg.user;
  userHome = "/Users/${user}";

  enabledCount = lib.count (x: x) [
    cfg.daemon.enable
    cfg.kanata-tray.enable
    cfg.kanata-bar.enable
  ];
in

{
  imports = [
    (import ./modules/daemon.nix)
    (import ./modules/kanata-tray.nix { inherit kanata-tray darwin-smapp; })
    (import ./modules/kanata-bar.nix { inherit darwin-smapp; })
    darwin-smapp.darwinModules.default
  ];

  options.services.kanata = {
    enable = lib.mkEnableOption "kanata keyboard remapper with Karabiner DriverKit";

    sudoers = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Add NOPASSWD sudoers entry for kanata.
        Defaults to `true`. Required for clean process termination in tray mode
        and to avoid the fragile TCC sqlite3 hack in daemon mode.
      '';
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = config.system.primaryUser;
      description = "Username for sudoers, user agent, and file paths. Defaults to system.primaryUser.";
    };

    configFile = lib.mkOption {
      type = lib.types.str;
      default = "${userHome}/.config/kanata/kanata.kbd";
      description = "Path to kanata configuration file.";
    };

    configSource = lib.mkOption {
      type = lib.types.nullOr (lib.types.either lib.types.path lib.types.str);
      default = null;
      description = ''
        If set, configFile will be symlinked to this path.
        Use a string for an out-of-store symlink (edits take effect without rebuild):
          configSource = "/Users/you/.nix-config/kanata.kbd";
        Use a path to copy into the nix store (immutable, requires rebuild):
          configSource = ./kanata.kbd;
      '';
    };

    package = lib.mkPackageOption pkgs "kanata" {
      default = "kanata-with-cmd";
    };

    smapp = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Use SMAppService wrapper for LaunchAgent registration.
        When enabled, kanata-bar and kanata-tray appear with proper icons in
        System Settings > Login Items instead of generic "sh" entries.
        Set to false for legacy launchd behavior.
      '';
    };
  };

  config = lib.mkMerge [
    # Always stop kanata before launchd services are reconfigured — even when
    # the module is being disabled. Without this, removing kanata can leave HID
    # input captured with no output.
    {
      system.activationScripts.preActivation.text = lib.mkAfter ''
        /usr/bin/pkill -KILL -x kanata 2>/dev/null && echo "kanata: stopped running kanata process" || true
        /usr/bin/pkill -x kanata-tray 2>/dev/null && echo "kanata: stopped running kanata-tray process" || true
        /usr/bin/pkill -x kanata-bar 2>/dev/null && echo "kanata: stopped running kanata-bar process" || true
      '';

      # Clean up stale launchd agents after nix-darwin has reconciled launchd state.
      # Only removes labels not used by the current configuration.
      system.activationScripts.postActivation.text =
        let
          # Determine which labels are active in current config
          activeLabels =
            lib.optional (cfg.enable && cfg.kanata-bar.enable && cfg.kanata-bar.autostart && !cfg.smapp) "com.kanata-bar.launchd"
            ++ lib.optional (cfg.enable && cfg.kanata-bar.enable && cfg.kanata-bar.autostart && cfg.smapp) "com.kanata-bar.agent"
            ++ lib.optional (cfg.enable && cfg.kanata-tray.enable && cfg.kanata-tray.autostart && !cfg.smapp) "org.kanata.tray.launchd"
            ++ lib.optional (cfg.enable && cfg.kanata-tray.enable && cfg.kanata-tray.autostart && cfg.smapp) "org.kanata.tray.agent"
            ++ lib.optional (cfg.enable && cfg.daemon.enable) "org.kanata.daemon";
          allLabels = [ "com.kanata-bar" "com.kanata-bar.launchd" "com.kanata-bar.agent" "org.kanata.tray" "org.kanata.tray.launchd" "org.kanata.tray.agent" "org.kanata.daemon" ];
          staleLabels = lib.subtractLists activeLabels allLabels;
        in
        lib.optionalString (staleLabels != []) ''
          for label in ${lib.concatStringsSep " " staleLabels}; do
            if launchctl list "$label" &>/dev/null; then
              launchctl remove "$label" 2>/dev/null && echo "kanata: removed stale $label agent" || true
            fi
          done
        '';
    }

    (lib.mkIf cfg.enable {
      assertions = [
        {
          assertion = enabledCount <= 1;
          message = "services.kanata: enable at most one of daemon, kanata-tray, kanata-bar";
        }
      ];

      environment.systemPackages = [ cfg.package ];

      # Karabiner DriverKit VirtualHIDDevice installation and activation
      system.activationScripts.postActivation.text = lib.mkAfter ''
        INSTALLED_VERSION=$(pkgutil --pkg-info org.pqrs.Karabiner-DriverKit-VirtualHIDDevice 2>/dev/null | grep "version:" | awk '{print $2}' || true)
        MANAGER="/Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/MacOS/Karabiner-VirtualHIDDevice-Manager"
        if [ "$INSTALLED_VERSION" != "${karabiner-driver-version}" ] || [ ! -x "$MANAGER" ]; then
          echo "kanata: installing Karabiner DriverKit VirtualHIDDevice ${karabiner-driver-version} (current: $INSTALLED_VERSION)"
          installer -pkg "${karabiner-driver-pkg}" -target /
        else
          echo "kanata: Karabiner DriverKit VirtualHIDDevice ${karabiner-driver-version} already installed"
        fi

        if [ -x "$MANAGER" ]; then
          "$MANAGER" activate >/dev/null 2>&1 || true
        fi

        ${lib.optionalString (cfg.configSource != null) ''
          # Symlink kanata config
          sudo --user="${user}" -- mkdir -p "$(dirname "${cfg.configFile}")"
          sudo --user="${user}" -- ln -sf ${cfg.configSource} "${cfg.configFile}"
        ''}
      '';

      launchd.daemons.karabiner-vhid = {
        serviceConfig = {
          Label = "org.pqrs.Karabiner-VirtualHIDDevice-Daemon";
          Program = "/Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications/Karabiner-VirtualHIDDevice-Daemon.app/Contents/MacOS/Karabiner-VirtualHIDDevice-Daemon";
          RunAtLoad = true;
          KeepAlive = true;
        };
      };

      # sudoers NOPASSWD entry for kanata and pkill
      security.sudo.extraConfig = lib.mkIf (cfg.sudoers && enabledCount > 0)
        "${user} ALL=(root) NOPASSWD: ${cfg.package}/bin/kanata, /usr/bin/pkill -x kanata";
    })
  ];
}
