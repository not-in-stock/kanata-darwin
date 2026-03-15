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

  kanata-bar-version = "1.1.1";
  kanata-bar-zip = pkgs.fetchurl {
    url = "https://github.com/not-in-stock/kanata-bar/releases/download/v${kanata-bar-version}/kanata-bar.app.zip";
    hash = "sha256-dsfPifT+pOxOE2/UfQzyugwuqSbomKP6D5Deo+wVyew=";
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

  barConfig = tomlFormat.generate "kanata-bar.toml" (
    lib.recursiveUpdate barBaseConfig cfg.kanata-bar.settings
  );
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
    launchd = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = "Extra attributes shallow-merged into the launchd service config (nested keys are replaced, not deep-merged).";
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

  config = lib.mkIf (cfg.enable && cfg.kanata-bar.enable) {
    environment.systemPackages = [ cfg.kanata-bar.package ];

    system.activationScripts.postActivation.text = lib.mkAfter ''
      # Install kanata-bar config
      sudo --user="${user}" -- mkdir -p "${userHome}/.config/kanata-bar"
      sudo --user="${user}" -- cp -f ${barConfig} "${userHome}/.config/kanata-bar/config.toml"
    '';

    launchd.user.agents.kanata-bar = lib.mkIf cfg.kanata-bar.autostart {
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
  };
}
