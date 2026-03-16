{ kanata-tray }:
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
  tomlFormat = pkgs.formats.toml { };

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

  # kanata-tray connects to "localhost" which Go resolves to [::1] (IPv6 first),
  # but kanata listens on 127.0.0.1 (IPv4 only). Patch to use 127.0.0.1 directly.
  # TODO: remove patch when fixed upstream
  kanata-tray-patched = (kanata-tray.packages.${pkgs.stdenv.hostPlatform.system}.kanata-tray).overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      substituteInPlace runner/tcp_client/tcp_client.go \
        --replace-fail '"localhost:%d"' '"127.0.0.1:%d"'
    '';
  });

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
in

{
  options.services.kanata.kanata-tray = {
    enable = lib.mkEnableOption "kanata-tray GUI launcher";
    package = lib.mkOption {
      type = lib.types.package;
      default = kanata-tray-patched;
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
    smapp = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Use SMAppService wrapper for LaunchAgent registration.
        When enabled, kanata-tray appears with its proper icon in
        System Settings > Login Items instead of a generic "sh" entry.
        Set to false for legacy launchd behavior.
      '';
    };
    extraLaunchdConfig = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = ''
        Extra launchd plist keys (e.g. KeepAlive, ThrottleInterval).
        Applied in both smapp and legacy modes. Shallow-merged (nested keys are replaced, not deep-merged).
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
    settings = lib.mkOption {
      type = tomlFormat.type;
      default = { };
      description = "Extra settings merged into kanata-tray.toml.";
    };
  };

  config = lib.mkIf (cfg.enable && cfg.kanata-tray.enable) {
    environment.systemPackages = [ kanata-tray-app ];

    system.activationScripts.postActivation.text = lib.mkAfter ''
      # Create sudo-kanata wrapper
      sudo --user="${user}" -- mkdir -p "${userHome}/.local/bin"
      sudo --user="${user}" -- cp -f ${sudoKanataWrapper} "${userHome}/.local/bin/sudo-kanata"
      sudo --user="${user}" -- chmod +x "${userHome}/.local/bin/sudo-kanata"

      # Install kanata-tray TOML config
      sudo --user="${user}" -- mkdir -p "${userHome}/Library/Application Support/kanata-tray"
      sudo --user="${user}" -- cp -f ${trayConfig} "${userHome}/Library/Application Support/kanata-tray/kanata-tray.toml"

      ${lib.optionalString (cfg.kanata-tray.icons != { }) ''
        # Install layer icons
        sudo --user="${user}" -- mkdir -p "${userHome}/Library/Application Support/kanata-tray/icons"
        ${lib.concatStringsSep "\n" (lib.mapAttrsToList (
          name: path:
          ''sudo --user="${user}" -- cp -f ${path} "${userHome}/Library/Application Support/kanata-tray/icons/${builtins.baseNameOf path}"''
        ) cfg.kanata-tray.icons)}
      ''}
    '';

    # SMAppService wrapper — proper icon in Login Items
    services.darwin-smapp = lib.mkIf (cfg.kanata-tray.smapp && cfg.kanata-tray.autostart) {
      enable = true;
      bundles.kanata-tray = {
        bundleIdentifier = "org.kanata.tray.smapp";
        bundleName = "Kanata Tray";
        services."org.kanata.tray.agent" = {
          command = "exec ${kanata-tray-app}/Applications/Kanata\\ Tray.app/Contents/MacOS/kanata-tray";
          extraPlistKeys = {
            KeepAlive = false;
            StandardOutPath = "/tmp/kanata-tray.log";
            StandardErrorPath = "/tmp/kanata-tray.err";
          } // cfg.kanata-tray.extraLaunchdConfig;
        };
      };
    };

    # Legacy launchd — fallback when smapp is disabled
    launchd.user.agents.kanata-tray = lib.mkIf (!cfg.kanata-tray.smapp && cfg.kanata-tray.autostart) {
      serviceConfig =
        {
          Label = "org.kanata.tray.launchd";
          ProgramArguments = [ "${kanata-tray-app}/Applications/Kanata Tray.app/Contents/MacOS/kanata-tray" ];
          RunAtLoad = true;
          KeepAlive = false;
          StandardOutPath = "/tmp/kanata-tray.log";
          StandardErrorPath = "/tmp/kanata-tray.err";
        }
        // cfg.kanata-tray.extraLaunchdConfig;
    };
  };
}
