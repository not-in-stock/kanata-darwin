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

  user = cfg.user;
  userHome = "/Users/${user}";

  # --- kanata-bar package ---
  kanata-bar-version = "1.0.1";
  kanata-bar-zip = pkgs.fetchurl {
    url = "https://github.com/not-in-stock/kanata-bar/releases/download/v${kanata-bar-version}/kanata-bar.app.zip";
    hash = "sha256-ynm+MRNsjIVx27iZiiANxOxidLuv6WfdTNKBjUPqKIE=";
  };
  kanata-bar-app = pkgs.stdenv.mkDerivation {
    pname = "kanata-bar-app";
    version = kanata-bar-version;
    src = kanata-bar-zip;
    dontUnpack = true;
    nativeBuildInputs = [ pkgs.unzip ];
    installPhase = ''
      mkdir -p "$out/Applications"
      unzip $src -d "$out/Applications"
    '';
  };

  # --- kanata-bar config generation ---
  barIconsDir = lib.optionalAttrs (cfg.kanata-bar.icons != { }) (
    pkgs.runCommand "kanata-bar-icons" { } ''
      mkdir -p $out
      ${lib.concatStringsSep "\n" (lib.mapAttrsToList (
        name: path: "cp ${path} $out/${name}.png"
      ) cfg.kanata-bar.icons)}
    ''
  );

  barBaseConfig =
    {
      kanata = "${cfg.package}/bin/kanata";
      config = cfg.configFile;
      port = 5829;
      pam_tid = if cfg.sudoers then "auto" else "false";
      autostart = true;
      autorestart = true;
      extra_args = [ "--nodelay" ];
    }
    // lib.optionalAttrs (cfg.kanata-bar.icons != { }) {
      icons_dir = "${barIconsDir}";
    };

  barConfig = tomlFormat.generate "kanata-bar.toml" (
    lib.recursiveUpdate barBaseConfig cfg.kanata-bar.settings
  );

  # --- kanata-tray ---
  # Layer icons config for kanata-tray TOML
  layerIconsConfig = lib.optionalAttrs (cfg.kanata-tray.icons != { }) {
    defaults.layer_icons = lib.mapAttrs (name: path: builtins.baseNameOf path) cfg.kanata-tray.icons;
  };

  trayConfig = tomlFormat.generate "kanata-tray.toml" (
    lib.recursiveUpdate
      (lib.recursiveUpdate
        {
          defaults = {
            kanata_executable = "${userHome}/.local/bin/sudo-kanata";
            tcp_port = 5829;
            autorestart_on_crash = true;
          };
          presets.default = {
            kanata_config = cfg.configFile;
            autorun = true;
            extra_args = [ "--nodelay" ];
          };
        }
        layerIconsConfig
      )
      cfg.kanata-tray.settings
  );

  sudoKanataWrapper = pkgs.writeScript "sudo-kanata" (
    if cfg.sudoers then
      ''
        #!/bin/bash
        /usr/bin/sudo /usr/bin/pkill -x kanata 2>/dev/null
        /usr/bin/sudo ${cfg.package}/bin/kanata "$@" &
        KANATA_PID=$!
        # Monitor: when this wrapper is killed (SIGKILL from kanata-tray),
        # detect death via kill -0 and clean up kanata.
        (while kill -0 $$ 2>/dev/null; do sleep 0.5; done
         /usr/bin/sudo /usr/bin/pkill -x kanata 2>/dev/null) &
        wait $KANATA_PID
      ''
    else
      ''
        #!/bin/bash
        /usr/bin/sudo /bin/sh -c '/usr/bin/pkill -x kanata 2>/dev/null; exec ${cfg.package}/bin/kanata "$@"' -- "$@" &
        KANATA_PID=$!
        # Monitor: when wrapper is killed, prompt user to authenticate and kill kanata.
        (while kill -0 $$ 2>/dev/null; do sleep 0.5; done
         /usr/bin/osascript -e 'do shell script "/usr/bin/pkill -x kanata" with administrator privileges' 2>/dev/null) &
        wait $KANATA_PID
      ''
  );

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
      exec ${cfg.kanata-tray.package}/bin/kanata-tray "\$@"
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
  # Only when daemon mode enabled and sudoers is disabled.
  useTccHack = cfg.daemon.enable && !cfg.sudoers;

  # Whether kanata runs via sudo (user agent or tray wrapper).
  usesSudo = (cfg.daemon.enable && cfg.sudoers) || cfg.kanata-tray.enable;

  # Count how many launch submodules are enabled
  enabledCount = lib.count (x: x) [
    cfg.daemon.enable
    cfg.kanata-tray.enable
    cfg.kanata-bar.enable
  ];
in

{
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

    # --- daemon submodule ---
    daemon = {
      enable = lib.mkEnableOption "headless kanata launchd service";
      launchd = lib.mkOption {
        type = lib.types.attrs;
        default = { };
        description = "Extra attributes merged into the launchd service config.";
      };
    };

    # --- kanata-tray submodule ---
    kanata-tray = {
      enable = lib.mkEnableOption "kanata-tray GUI launcher";
      package = lib.mkOption {
        type = lib.types.package;
        default = kanata-tray.packages.${pkgs.stdenv.hostPlatform.system}.kanata-tray;
        description = "The kanata-tray package.";
      };
      autostart = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Whether to create a launchd user agent that starts kanata-tray automatically at login.
          When false, the .app bundle is still available in /Applications/Nix Apps/.
        '';
      };
      launchd = lib.mkOption {
        type = lib.types.attrs;
        default = { };
        description = "Extra attributes merged into the launchd service config.";
      };
      icons = lib.mkOption {
        type = lib.types.attrsOf lib.types.path;
        default = { };
        description = ''
          Map of kanata layer names to icon files (PNG recommended).
          Use `mkLayerIcons` to generate icons from font glyphs.
        '';
        example = lib.literalExpression ''{ nav = ./icons/nav.png; }'';
      };
      settings = lib.mkOption {
        type = tomlFormat.type;
        default = { };
        description = "Extra settings merged into kanata-tray.toml.";
      };
    };

    # --- kanata-bar submodule ---
    kanata-bar = {
      enable = lib.mkEnableOption "kanata-bar GUI launcher";
      package = lib.mkOption {
        type = lib.types.package;
        default = kanata-bar-app;
        description = "The kanata-bar .app package.";
      };
      autostart = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Whether to create a launchd user agent that starts kanata-bar automatically at login.
          When false, you can start it manually from /Applications/Nix Apps/.
        '';
      };
      launchd = lib.mkOption {
        type = lib.types.attrs;
        default = { };
        description = "Extra attributes merged into the launchd service config.";
      };
      settings = lib.mkOption {
        type = tomlFormat.type;
        default = { };
        description = ''
          Settings merged into kanata-bar config.toml.
          Auto-propagated defaults: kanata, config, port, pam_tid, autostart, autorestart, extra_args.
        '';
      };
      icons = lib.mkOption {
        type = lib.types.attrsOf lib.types.path;
        default = { };
        description = ''
          Map of kanata layer names to icon files (PNG recommended).
          Use `mkLayerIcons` to generate icons from font glyphs.
        '';
        example = lib.literalExpression ''{ nav = ./icons/nav.png; }'';
      };
    };
  };

  config = lib.mkMerge [
    # Always stop kanata before launchd services are reconfigured — even when
    # the module is being disabled. Without this, removing kanata can leave HID
    # input captured with no output: kanata holds the real keyboard but the
    # virtual HID device (karabiner-vhid) may already be gone.
    {
      system.activationScripts.preActivation.text = lib.mkAfter ''
        /usr/bin/pkill -x kanata 2>/dev/null && echo "kanata: stopped running kanata process" || true
        /usr/bin/pkill -x kanata-tray 2>/dev/null && echo "kanata: stopped running kanata-tray process" || true
        /usr/bin/pkill -x kanata-bar 2>/dev/null && echo "kanata: stopped running kanata-bar process" || true
      '';
    }

    (lib.mkIf cfg.enable {
      assertions = [
        {
          assertion = enabledCount <= 1;
          message = "services.kanata: enable at most one of daemon, kanata-tray, kanata-bar";
        }
      ];

      warnings = lib.optional useTccHack ''
        services.kanata: running in daemon mode with sudoers=false uses a fragile TCC sqlite3 hack
        to grant Input Monitoring permission. Apple may change the TCC.db schema in future macOS
        updates, which would silently break kanata — or worse, corrupt the TCC database.
        Consider using sudoers=true (default) or kanata-bar/kanata-tray instead.
      '';

      environment.systemPackages =
        [ cfg.package ]
        ++ lib.optional cfg.kanata-tray.enable kanata-tray-app
        ++ lib.optional cfg.kanata-bar.enable cfg.kanata-bar.package;

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

        ${lib.optionalString cfg.kanata-tray.enable ''
          # Create sudo-kanata wrapper
          sudo --user=${user} -- mkdir -p "${userHome}/.local/bin"
          sudo --user=${user} -- cp -f ${sudoKanataWrapper} "${userHome}/.local/bin/sudo-kanata"
          sudo --user=${user} -- chmod +x "${userHome}/.local/bin/sudo-kanata"

          # Install kanata-tray TOML config
          sudo --user=${user} -- mkdir -p "${userHome}/Library/Application Support/kanata-tray"
          sudo --user=${user} -- cp -f ${trayConfig} "${userHome}/Library/Application Support/kanata-tray/kanata-tray.toml"

          ${lib.optionalString (cfg.kanata-tray.icons != { }) ''
            # Install layer icons
            sudo --user=${user} -- mkdir -p "${userHome}/Library/Application Support/kanata-tray/icons"
            ${lib.concatStringsSep "\n" (lib.mapAttrsToList (
              name: path:
              ''sudo --user=${user} -- cp -f ${path} "${userHome}/Library/Application Support/kanata-tray/icons/${builtins.baseNameOf path}"''
            ) cfg.kanata-tray.icons)}
          ''}
        ''}

        ${lib.optionalString cfg.kanata-bar.enable ''
          # Install kanata-bar config
          sudo --user=${user} -- mkdir -p "${userHome}/.config/kanata-bar"
          sudo --user=${user} -- cp -f ${barConfig} "${userHome}/.config/kanata-bar/config.toml"
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
          // cfg.daemon.launchd;
      };

      # daemon + sudoers=true: user agent via sudo NOPASSWD (no TCC hack)
      launchd.user.agents.kanata = lib.mkIf (cfg.daemon.enable && cfg.sudoers) {
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
          // cfg.daemon.launchd;
      };

      # sudoers NOPASSWD entry for kanata and pkill
      security.sudo.extraConfig = lib.mkIf (cfg.sudoers && enabledCount > 0)
        "${user} ALL=(root) NOPASSWD: ${cfg.package}/bin/kanata, /usr/bin/pkill -x kanata";

      # kanata-tray: user agent
      launchd.user.agents.kanata-tray = lib.mkIf (cfg.kanata-tray.enable && cfg.kanata-tray.autostart) {
        serviceConfig =
          {
            Label = "org.kanata.tray";
            ProgramArguments = [ "${kanata-tray-app}/Applications/Kanata Tray.app/Contents/MacOS/kanata-tray" ];
            RunAtLoad = true;
            KeepAlive = false;
            StandardOutPath = "/tmp/kanata-tray.log";
            StandardErrorPath = "/tmp/kanata-tray.err";
          }
          // cfg.kanata-tray.launchd;
      };

      # kanata-bar: user agent
      launchd.user.agents.kanata-bar = lib.mkIf (cfg.kanata-bar.enable && cfg.kanata-bar.autostart) {
        serviceConfig =
          {
            Label = "com.kanata-bar";
            ProgramArguments = [
              "${cfg.kanata-bar.package}/Applications/Kanata Bar.app/Contents/MacOS/kanata-bar"
              "--config-file"
              "${userHome}/.config/kanata-bar/config.toml"
            ];
            RunAtLoad = true;
            KeepAlive = false;
            StandardOutPath = "/tmp/kanata-bar.log";
            StandardErrorPath = "/tmp/kanata-bar.err";
          }
          // cfg.kanata-bar.launchd;
      };
    })
  ];
}
