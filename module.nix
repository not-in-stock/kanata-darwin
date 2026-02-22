{ kanata-tray }:
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

  tomlFormat = pkgs.formats.toml { };
  trayConfig = tomlFormat.generate "kanata-tray.toml" (lib.recursiveUpdate {
    defaults = {
      kanata_executable = "/Users/${cfg.user}/.local/bin/sudo-kanata";
      tcp_port = 5829;
      autorestart_on_crash = true;
    };
    presets.default = {
      kanata_config = cfg.configFile;
      autorun = true;
      extra_args = [ "--nodelay" ];
    };
  } cfg.tray.settings);

  user = cfg.user;
  userHome = "/Users/${user}";

  sudoKanataWrapper = pkgs.writeScript "sudo-kanata" (if cfg.sudoers then ''
    #!/bin/sh
    /usr/bin/sudo /usr/bin/pkill -x kanata 2>/dev/null
    exec /usr/bin/sudo ${cfg.package}/bin/kanata "$@"
  '' else ''
    #!/bin/sh
    exec /usr/bin/sudo /bin/sh -c '/usr/bin/pkill -x kanata 2>/dev/null; exec ${cfg.package}/bin/kanata "$@"' -- "$@"
  '');

  kanata-icon = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/jtroo/kanata/refs/heads/main/assets/kanata-icon.svg";
    hash = "sha256-wq2wNj8Imc2xIO5poCXM4EcN42F2cP2wESTtOHbSFNs=";
  };

  kanata-tray-app = pkgs.stdenv.mkDerivation {
    pname = "kanata-tray-app";
    version = "1.0";
    dontUnpack = true;
    nativeBuildInputs = [ pkgs.librsvg ];
    buildPhase = ''
      rsvg-convert -w 512 -h 512 ${kanata-icon} -o AppIcon.png
    '';
    installPhase = ''
      APP="$out/Applications/Kanata Tray.app/Contents"
      mkdir -p "$APP/MacOS" "$APP/Resources"
      cp AppIcon.png "$APP/Resources/"
      cat > "$APP/MacOS/kanata-tray" << WRAPPER
      #!/bin/sh
      exec ${cfg.tray.package}/bin/kanata-tray "\$@"
      WRAPPER
      chmod +x "$APP/MacOS/kanata-tray"
      cat > "$APP/Info.plist" << 'EOF'
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
        <key>CFBundleName</key>
        <string>Kanata Tray</string>
        <key>CFBundleIdentifier</key>
        <string>org.kanata.tray</string>
        <key>CFBundleVersion</key>
        <string>1.0</string>
        <key>CFBundleExecutable</key>
        <string>kanata-tray</string>
        <key>CFBundleIconFile</key>
        <string>AppIcon.png</string>
        <key>CFBundlePackageType</key>
        <string>APPL</string>
        <key>LSUIElement</key>
        <true/>
      </dict>
      </plist>
      EOF
    '';
  };

  # Whether to run kanata as a root launchd daemon with TCC sqlite3 hack.
  # Only when mode=daemon and sudoers is disabled.
  useTccHack = cfg.mode == "daemon" && !cfg.sudoers;

  # Whether kanata runs via sudo (user agent or tray wrapper).
  usesSudo = cfg.mode == "daemon" && cfg.sudoers || cfg.mode == "tray";
in

{
  options.services.kanata = {
    enable = lib.mkEnableOption "kanata keyboard remapper with Karabiner DriverKit";

    mode = lib.mkOption {
      type = lib.types.enum [ "daemon" "tray" ];
      default = "tray";
      description = ''
        How kanata is launched:
        - `daemon` — headless, no GUI. With `sudoers = true` (default): user launchd agent
          via sudo NOPASSWD. With `sudoers = false`: root launchd daemon with TCC sqlite3 hack.
        - `tray` — launched by kanata-tray GUI via sudo. With `sudoers = false` (default):
          prompts for TouchID/password on each start. With `sudoers = true`: no prompts.
      '';
    };

    sudoers = lib.mkOption {
      type = lib.types.bool;
      default = cfg.mode == "daemon";
      description = ''
        Add NOPASSWD sudoers entry for kanata.
        Defaults to `true` for daemon mode (avoids fragile TCC sqlite3 hack),
        `false` for tray mode (user authenticates via TouchID/password).
      '';
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = config.system.primaryUser;
      description = "Username for sudoers, user agent, and file paths. Defaults to system.primaryUser.";
    };

    configFile = lib.mkOption {
      type = lib.types.str;
      default = "${userHome}/Library/Application Support/kanata/kanata.kbd";
      description = "Path to kanata configuration file.";
    };

    configSource = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "If set, configFile will be symlinked to this path.";
    };

    package = lib.mkPackageOption pkgs "kanata" {
      default = "kanata-with-cmd";
    };

    tray.package = lib.mkOption {
      type = lib.types.package;
      default = kanata-tray.packages.${pkgs.stdenv.hostPlatform.system}.kanata-tray;
      description = "The kanata-tray package.";
    };

    tray.autostart = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether to create a launchd user agent that starts kanata-tray automatically at login.
        When false, the .app bundle is still available in /Applications/Nix Apps/ — you can
        add it to System Settings → General → Login Items → Open at Login manually.
      '';
    };

    tray.settings = lib.mkOption {
      type = tomlFormat.type;
      default = { };
      description = "Extra settings merged into kanata-tray.toml.";
    };
  };

  config = lib.mkIf cfg.enable {
    warnings = lib.optional useTccHack ''
      services.kanata: running in daemon mode with sudoers=false uses a fragile TCC sqlite3 hack
      to grant Input Monitoring permission. Apple may change the TCC.db schema in future macOS
      updates, which would silently break kanata — or worse, corrupt the TCC database.
      Consider using sudoers=true (default) or mode="tray" instead.
    '';

    environment.systemPackages = [ cfg.package ]
      ++ lib.optional (cfg.mode == "tray") kanata-tray-app;

    system.activationScripts.postActivation.text = lib.mkAfter ''
      # Install Karabiner DriverKit VirtualHIDDevice if not present or outdated.
      # The pkg must be installed outside nix store — macOS rejects code signatures from store paths.
      INSTALLED_VERSION=$(pkgutil --pkg-info org.pqrs.Karabiner-DriverKit-VirtualHIDDevice 2>/dev/null | grep "version:" | awk '{print $2}' || true)
      MANAGER="/Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/MacOS/Karabiner-VirtualHIDDevice-Manager"
      if [ "$INSTALLED_VERSION" != "${karabiner-driver-version}" ] || [ ! -x "$MANAGER" ]; then
        echo "kanata: installing Karabiner DriverKit VirtualHIDDevice ${karabiner-driver-version} (current: $INSTALLED_VERSION)"
        installer -pkg "${karabiner-driver-pkg}" -target /
      else
        echo "kanata: Karabiner DriverKit VirtualHIDDevice ${karabiner-driver-version} already installed"
      fi

      # Activate the driver extension. On first run, macOS shows a system dialog requiring approval.
      # On subsequent runs, this is a no-op (idempotent).
      if [ -x "$MANAGER" ]; then
        "$MANAGER" activate 2>&1 || true
      fi

      ${lib.optionalString useTccHack ''
      # Grant kanata Input Monitoring (kTCCServiceListenEvent) permission via TCC sqlite3 hack.
      # Only needed when running as root daemon without sudoers — sudo provides sufficient
      # privileges for IOHIDDeviceOpen without a TCC entry.
      # WARNING: fragile — Apple may change TCC.db schema in future macOS versions.
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
      ''}

      ${lib.optionalString (cfg.mode == "tray") ''
      # Create sudo-kanata wrapper
      sudo --user=${user} -- mkdir -p "${userHome}/.local/bin"
      sudo --user=${user} -- cp -f ${sudoKanataWrapper} "${userHome}/.local/bin/sudo-kanata"
      sudo --user=${user} -- chmod +x "${userHome}/.local/bin/sudo-kanata"

      # Install kanata-tray TOML config
      sudo --user=${user} -- mkdir -p "${userHome}/Library/Application Support/kanata-tray"
      sudo --user=${user} -- cp -f ${trayConfig} "${userHome}/Library/Application Support/kanata-tray/kanata-tray.toml"
      ''}

      ${lib.optionalString (cfg.configSource != null) ''
      # Symlink kanata config
      sudo --user=${user} -- mkdir -p "$(dirname "${cfg.configFile}")"
      sudo --user=${user} -- ln -sf ${cfg.configSource} "${cfg.configFile}"
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

    # daemon + sudoers=false: root launchd daemon (requires TCC hack)
    launchd.daemons.kanata = lib.mkIf useTccHack {
      serviceConfig = {
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
      };
    };

    # daemon + sudoers=true: user agent via sudo NOPASSWD (no TCC hack)
    launchd.user.agents.kanata = lib.mkIf (cfg.mode == "daemon" && cfg.sudoers) {
      serviceConfig = {
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
      };
    };

    # sudoers NOPASSWD entry for kanata and pkill (used by sudo-kanata wrapper)
    security.sudo.extraConfig = lib.mkIf cfg.sudoers
      "${user} ALL=(root) NOPASSWD: ${cfg.package}/bin/kanata, /usr/bin/pkill -x kanata";

    # tray mode: kanata-tray user agent (not created when loginItem=true)
    launchd.user.agents.kanata-tray = lib.mkIf (cfg.mode == "tray" && cfg.tray.autostart) {
      serviceConfig = {
        Label = "org.kanata.tray";
        ProgramArguments = [ "${kanata-tray-app}/Applications/Kanata Tray.app/Contents/MacOS/kanata-tray" ];
        RunAtLoad = true;
        KeepAlive = false;
        StandardOutPath = "/tmp/kanata-tray.log";
        StandardErrorPath = "/tmp/kanata-tray.err";
      };
    };
  };
}
