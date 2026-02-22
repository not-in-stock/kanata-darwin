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

  # Generate icons from labels using imagemagick (tray mode only)
  generatedIcons = lib.optionalAttrs (cfg.mode == "tray" && cfg.tray.icons.labels != { }) (
    let
      iconsPkg = pkgs.runCommand "kanata-layer-icons"
        { nativeBuildInputs = [ pkgs.imagemagick cfg.tray.icons.font ]; }
        ''
          mkdir -p $out
          FONT=$(find ${cfg.tray.icons.font} -name '*.ttf' -o -name '*.otf' | head -1)
          if [ -z "$FONT" ]; then
            echo "error: no TTF/OTF font found in ${cfg.tray.icons.font}" >&2
            exit 1
          fi

          gen_icon() {
            local name="$1" label="$2"
            local target=88  # 128 - 2*20 padding

            # Convert U+XXXX codepoint syntax to actual UTF-8 character
            if [[ "$label" =~ ^U\+([0-9A-Fa-f]+)$ ]]; then
              label=$(printf "\\U''${BASH_REMATCH[1]}")
            fi

            # Render glyph large, trim to actual bounds, resize to fit target area
            magick -background none -fill white -font "$FONT" -pointsize 200 \
              label:"$label" -trim +repage \
              -resize "''${target}x''${target}" \
              -gravity center -extent 128x128 \
              $TMPDIR/glyph.png

            # Composite: rounded rect with glyph cut out
            magick -size 128x128 xc:none \
              -fill white -draw "roundrectangle 4,4 123,123 20,20" \
              $TMPDIR/glyph.png \
              -compose Dst_Out -composite \
              $out/$name.png
          }

          ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: label:
            "gen_icon ${lib.escapeShellArg name} ${lib.escapeShellArg label}"
          ) cfg.tray.icons.labels)}
        '';
    in
    lib.mapAttrs (name: _: "${iconsPkg}/${name}.png") cfg.tray.icons.labels
  );

  # Merge generated + manual icons (files take priority)
  allIcons = generatedIcons // cfg.tray.icons.files;

  # Generate layer_icons TOML section: map layer names to filenames (basename only)
  layerIconsConfig = lib.optionalAttrs (allIcons != { }) {
    defaults.layer_icons = lib.mapAttrs (name: path: builtins.baseNameOf path) allIcons;
  };

  trayConfig = tomlFormat.generate "kanata-tray.toml" (lib.recursiveUpdate (lib.recursiveUpdate {
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
  } layerIconsConfig) cfg.tray.settings);

  user = cfg.user;
  userHome = "/Users/${user}";

  sudoKanataWrapper = pkgs.writeScript "sudo-kanata" (if cfg.sudoers then ''
    #!/bin/bash
    /usr/bin/sudo /usr/bin/pkill -x kanata 2>/dev/null
    /usr/bin/sudo ${cfg.package}/bin/kanata "$@" &
    KANATA_PID=$!
    # Monitor: when this wrapper is killed (SIGKILL from kanata-tray),
    # detect death via kill -0 and clean up kanata.
    (while kill -0 $$ 2>/dev/null; do sleep 0.5; done
     /usr/bin/sudo /usr/bin/pkill -x kanata 2>/dev/null) &
    wait $KANATA_PID
  '' else ''
    #!/bin/bash
    /usr/bin/sudo /bin/sh -c '/usr/bin/pkill -x kanata 2>/dev/null; exec ${cfg.package}/bin/kanata "$@"' -- "$@" &
    KANATA_PID=$!
    # Monitor: when wrapper is killed, prompt user to authenticate and kill kanata.
    (while kill -0 $$ 2>/dev/null; do sleep 0.5; done
     /usr/bin/osascript -e 'do shell script "/usr/bin/pkill -x kanata" with administrator privileges' 2>/dev/null) &
    wait $KANATA_PID
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

    tray.icons.labels = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = ''
        Map of kanata layer names to text labels or `U+XXXX` codepoints. When set,
        generates menu bar icons — a rounded rectangle with the label cut out from
        the alpha channel (adapts to light/dark mode). Each glyph is automatically
        scaled to fill the icon. Use `"*"` as a fallback icon.
      '';
      example = lib.literalExpression ''{ default = "U+F0B34"; nav = "U+F062"; }'';
    };

    tray.icons.font = lib.mkOption {
      type = lib.types.package;
      default = pkgs.liberation_ttf;
      description = "Font package (must contain .ttf or .otf files) used for generated layer icons.";
    };

    tray.icons.files = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      default = { };
      description = ''
        Map of kanata layer names to custom icon files (PNG recommended).
        These override generated icons for the same layer name.
      '';
      example = lib.literalExpression ''{ nav = ./icons/nav.png; }'';
    };

    tray.settings = lib.mkOption {
      type = tomlFormat.type;
      default = { };
      description = "Extra settings merged into kanata-tray.toml.";
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
      '';
    }

    (lib.mkIf cfg.enable {
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

      ${lib.optionalString (allIcons != { }) ''
      # Install layer icons
      sudo --user=${user} -- mkdir -p "${userHome}/Library/Application Support/kanata-tray/icons"
      ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: path:
        ''sudo --user=${user} -- cp -f ${path} "${userHome}/Library/Application Support/kanata-tray/icons/${builtins.baseNameOf path}"''
      ) allIcons)}
      ''}
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
  })];
}
