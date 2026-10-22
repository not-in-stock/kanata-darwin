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

  kanata-bar-version = "1.2.1";
  kanata-bar-zip = pkgs.fetchurl {
    url = "https://github.com/not-in-stock/kanata-bar/releases/download/v${kanata-bar-version}/kanata-bar.app.zip";
    hash = "sha256-eRUFWOquFJVh6zun6uwGYaokxQnCpNkKJL6uSXhV2Ic=";
  };
  kanata-bar-app = pkgs.stdenv.mkDerivation {
    pname = "kanata-bar-app";
    version = kanata-bar-version;
    src = kanata-bar-zip;
    dontUnpack = true;
    dontStrip = true;
    dontPatchELF = true;
    installPhase = ''
      mkdir -p "$out/Applications"
      /usr/bin/ditto -x -k $src "$out/Applications"
    '';
  };

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
      kanata = {
        path = "${cfg.package}/bin/kanata";
        config = cfg.configFile;
        port = 5829;
        extra_args = [ "--nodelay" ];
      };
      kanata_bar = {
        autostart_kanata = false;
        autorestart_kanata = true;
        pam_touchid = "auto";
      } // lib.optionalAttrs (cfg.kanata-bar.icons != { }) {
        icons_dir = "${barIconsDir}";
      };
    };

  barMerged = lib.recursiveUpdate barBaseConfig cfg.kanata-bar.settings;
  barKanata = barMerged.kanata;
  barConfig = tomlFormat.generate "kanata-bar.toml" barMerged;

  # The no-args privileged supervisor shipped in the app bundle (task 18 / 2b).
  # nix-darwin COPIES GUI apps into /Applications/Nix Apps (a real copy, NOT a
  # store symlink), and that copy is where the launchd agent runs the app and what
  # the app's SudoLauncher resolves to. So the sudo digest rule must PIN the
  # /Applications/Nix Apps path (what gets invoked), while we HASH the store copy
  # (guaranteed present at activation; byte-identical to the installed copy).
  appInstallPath = "/Applications/Nix Apps/Kanata Bar.app";
  runtimeSuperviseBin = "${appInstallPath}/Contents/MacOS/kanata-bar-supervise";
  storeSuperviseBin = "${cfg.kanata-bar.package}/Applications/Kanata Bar.app/Contents/MacOS/kanata-bar-supervise";

  # Root-owned launch spec the supervisor reads (installed to /etc at activation,
  # atomically with the digest rule). Values mirror config.toml so app ⇄ supervisor.
  specFile = pkgs.writeText "kanata-bar-supervise.env" ''
    KANATA_BIN=${barKanata.path}
    KANATA_CONFIG=${barKanata.config}
    KANATA_PORT=${toString barKanata.port}
    KANATA_EXTRA_ARGS=${lib.concatStringsSep " " (barKanata.extra_args or [ ])}
    KANATA_LOG=${userHome}/Library/Logs/kanata.log
  '';
in

{
  options.services.kanata.kanata-bar = {
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
    extraLaunchdConfig = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = ''
        Extra launchd plist keys (e.g. KeepAlive, ThrottleInterval).
        Shallow-merged (nested keys are replaced, not deep-merged).
      '';
    };
    settings = lib.mkOption {
      type = tomlFormat.type;
      default = { };
      description = ''
        Settings merged into kanata-bar config.toml.
        Auto-propagated defaults: kanata.{path,config,port,extra_args}, kanata_bar.{autostart_kanata,autorestart_kanata,pam_touchid}.
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

  config = lib.mkMerge [
   (lib.mkIf (cfg.enable && cfg.kanata-bar.enable) {
    environment.systemPackages = [ cfg.kanata-bar.package ];

    system.activationScripts.postActivation.text = lib.mkAfter ''
      # Install kanata-bar config
      sudo --user="${user}" -- mkdir -p "${userHome}/.config/kanata-bar"
      sudo --user="${user}" -- cp -f ${barConfig} "${userHome}/.config/kanata-bar/config.toml"

      # Restart kanata-bar (killed in preActivation; nix-darwin skips
      # launchd reload when the plist is unchanged).
      ${lib.optionalString cfg.kanata-bar.autostart ''
        launchctl kickstart -k "gui/$(id -u ${user})/com.kanata-bar.launchd" 2>/dev/null \
          && echo "kanata-bar: restarted" || true
      ''}

      # Digest-pinned prompt-free launch (task 18 / 2b). The app uses the supervisor
      # path iff the spec /etc/kanata-bar/supervise.env exists, so the spec and the
      # NOPASSWD digest rule must be written ATOMICALLY together — writing the spec
      # without a matching rule would send the app down `sudo -n` with no rule (fails,
      # no fallback). Both require sudoers=true AND the supervisor binary present in
      # the installed release; otherwise remove both so the app falls back cleanly to
      # the `sudo /bin/sh` prompt path.
      SPEC=/etc/kanata-bar/supervise.env
      RULE=/etc/sudoers.d/kanata-bar-supervise
      # Hash the store copy (guaranteed present during activation); pin the
      # /Applications/Nix Apps copy (what the app actually invokes). Both copies are
      # byte-identical, so the hash matches what sudo will verify at run time.
      HASHSRC="${storeSuperviseBin}"
      PINPATH="${runtimeSuperviseBin}"
      ${lib.optionalString cfg.sudoers ''
        echo "kanata-bar: [supervise] hashsrc=$HASHSRC exists=$([ -x "$HASHSRC" ] && echo y || echo n)"
        if [ -x "$HASHSRC" ]; then
          # Pin the binary's sha256 with NO args, so the passwordless grant can't be
          # repurposed to run anything else as root (the yabai `--load-sa` pattern).
          # visudo-checked and fail-closed.
          HASH=$(/usr/bin/shasum -a 256 "$HASHSRC" | /usr/bin/awk '{print $1}')
          # The bundle path contains a space ("Kanata Bar.app"); sudoers needs it
          # backslash-escaped in the command path.
          ESC=$(printf '%s' "$PINPATH" | /usr/bin/sed 's/ /\\ /g')
          TMP=$(mktemp)
          printf '%s ALL=(root) NOPASSWD: sha256:%s %s ""\n' "${user}" "$HASH" "$ESC" > "$TMP"
          if /usr/sbin/visudo -cf "$TMP" >/dev/null 2>&1; then
            /usr/bin/install -m 0440 -o root -g wheel "$TMP" "$RULE"
            /usr/bin/install -d -m 0755 -o root -g wheel /etc/kanata-bar
            # Root-owned 0444 spec: *what* the supervisor may launch (the privilege
            # boundary — an unprivileged process can't redirect it). Values mirror
            # config.toml (barMerged) so the app and supervisor agree.
            /usr/bin/install -m 0444 -o root -g wheel ${specFile} "$SPEC"
            echo "kanata-bar: [supervise] installed digest rule + spec (pin=$PINPATH)"
          else
            echo "kanata-bar: [supervise] WARNING rule failed visudo -c; removing spec+rule" >&2
            /usr/sbin/visudo -cf "$TMP" || true
            rm -f "$RULE" "$SPEC"
          fi
          rm -f "$TMP"
        else
          echo "kanata-bar: [supervise] binary not in this release; removing spec+rule (prompt fallback)"
          rm -f "$RULE" "$SPEC"
        fi
      ''}
      ${lib.optionalString (!cfg.sudoers) ''
        rm -f "$RULE" "$SPEC"
      ''}
    '';

    launchd.user.agents.kanata-bar = lib.mkIf cfg.kanata-bar.autostart {
      serviceConfig =
        {
          Label = "com.kanata-bar.launchd";
          ProgramArguments = [
            "/Applications/Nix Apps/Kanata Bar.app/Contents/MacOS/kanata-bar"
            "--config-file"
            "${userHome}/.config/kanata-bar/config.toml"
          ];
          RunAtLoad = true;
          KeepAlive = false;
          ProcessType = "Interactive";
          StandardOutPath = "/tmp/kanata-bar.log";
          StandardErrorPath = "/tmp/kanata-bar.err";
        }
        // cfg.kanata-bar.extraLaunchdConfig;
    };
   })

    # When kanata-bar is NOT the active mode, remove the digest spec+rule so a stale
    # /etc/kanata-bar/supervise.env can't send some other kanata-bar install (e.g. a
    # hand-built app at a different path) down the supervise path with no matching
    # rule. This runs unconditionally — a disabled module's own config never does.
    (lib.mkIf (!(cfg.enable && cfg.kanata-bar.enable)) {
      system.activationScripts.postActivation.text = lib.mkAfter ''
        rm -f /etc/kanata-bar/supervise.env /etc/sudoers.d/kanata-bar-supervise 2>/dev/null || true
      '';
    })
  ];
}
