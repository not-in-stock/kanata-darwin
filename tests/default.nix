# Evaluation tests for the kanata-darwin module.
# Each test evaluates the module with a specific configuration and asserts
# properties of the result. Tests are pure nix evaluation — no macOS required.
{
  pkgs,
  kanata-tray,
  darwin-smapp,
}:

let
  lib = pkgs.lib;

  # Stub nix-darwin options that our module sets but doesn't define
  darwinStubs = {
    options = {
      system.primaryUser = lib.mkOption {
        type = lib.types.str;
        default = "testuser";
        internal = true;
      };
      system.activationScripts.preActivation.text = lib.mkOption {
        type = lib.types.lines;
        default = "";
      };
      system.activationScripts.postActivation.text = lib.mkOption {
        type = lib.types.lines;
        default = "";
      };
      environment.systemPackages = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = [ ];
      };
      launchd.daemons = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = { };
      };
      launchd.user.agents = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = { };
      };
      security.sudo.extraConfig = lib.mkOption {
        type = lib.types.lines;
        default = "";
      };
      assertions = lib.mkOption {
        type = lib.types.listOf lib.types.unspecified;
        default = [ ];
      };
      warnings = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
      };
    };
  };

  # Evaluate the module with a given config overlay
  evalWith = configFn:
    lib.evalModules {
      modules = [
        darwinStubs
        (import ../module.nix { inherit kanata-tray darwin-smapp; })
        { _module.args = { inherit pkgs; }; }
        configFn
      ];
    };

  # Check that all assertions pass
  assertionsPass = eval:
    let
      failed = lib.filter (a: !a.assertion) eval.config.assertions;
    in
    if failed == [ ] then true
    else throw "Assertions failed: ${lib.concatMapStringsSep "; " (a: a.message) failed}";

  # Check that an assertion fails with a specific message substring
  assertionFails = eval: substring:
    let
      failed = lib.filter (a: !a.assertion) eval.config.assertions;
    in
    if failed == [ ] then throw "Expected assertion failure containing '${substring}' but all passed"
    else if lib.any (a: lib.hasInfix substring a.message) failed then true
    else throw "Expected assertion failure containing '${substring}' but got: ${lib.concatMapStringsSep "; " (a: a.message) failed}";

  # --- Test Definitions ---

  tests = {
    # 1. Module disabled — should evaluate cleanly
    disabled = let eval = evalWith { services.kanata.enable = false; };
    in assertionsPass eval;

    # 2. Enabled without launcher — base config only
    enabled-no-launcher = let eval = evalWith { services.kanata.enable = true; };
    in assertionsPass eval;

    # 3. kanata-bar defaults (smapp=true, autostart=true)
    kanata-bar-defaults =
      let
        eval = evalWith {
          services.kanata.enable = true;
          services.kanata.kanata-bar.enable = true;
        };
      in
      assert assertionsPass eval;
      # smapp bundle should be configured
      assert eval.config.services.darwin-smapp.enable;
      assert eval.config.services.darwin-smapp.bundles ? kanata-bar;
      # legacy launchd should NOT be set
      assert !(eval.config.launchd.user.agents ? kanata-bar);
      true;

    # 4. kanata-bar legacy mode
    kanata-bar-legacy =
      let
        eval = evalWith {
          services.kanata.enable = true;
          services.kanata.kanata-bar.enable = true;
          services.kanata.kanata-bar.smapp = false;
        };
      in
      assert assertionsPass eval;
      # legacy launchd should be set
      assert eval.config.launchd.user.agents ? kanata-bar;
      assert eval.config.launchd.user.agents.kanata-bar.serviceConfig.Label == "com.kanata-bar.launchd";
      # smapp should NOT be enabled by kanata-bar
      assert !(eval.config.services.darwin-smapp.bundles ? kanata-bar);
      true;

    # 5. kanata-bar without autostart
    kanata-bar-no-autostart =
      let
        eval = evalWith {
          services.kanata.enable = true;
          services.kanata.kanata-bar.enable = true;
          services.kanata.kanata-bar.autostart = false;
        };
      in
      assert assertionsPass eval;
      # no smapp, no launchd
      assert !(eval.config.services.darwin-smapp.bundles ? kanata-bar);
      assert !(eval.config.launchd.user.agents ? kanata-bar);
      true;

    # 6. kanata-tray defaults
    kanata-tray-defaults =
      let
        eval = evalWith {
          services.kanata.enable = true;
          services.kanata.kanata-tray.enable = true;
        };
      in
      assert assertionsPass eval;
      assert eval.config.services.darwin-smapp.enable;
      assert eval.config.services.darwin-smapp.bundles ? kanata-tray;
      assert !(eval.config.launchd.user.agents ? kanata-tray);
      true;

    # 7. kanata-tray legacy mode
    kanata-tray-legacy =
      let
        eval = evalWith {
          services.kanata.enable = true;
          services.kanata.kanata-tray.enable = true;
          services.kanata.kanata-tray.smapp = false;
        };
      in
      assert assertionsPass eval;
      assert eval.config.launchd.user.agents ? kanata-tray;
      assert eval.config.launchd.user.agents.kanata-tray.serviceConfig.Label == "org.kanata.tray.launchd";
      assert !(eval.config.services.darwin-smapp.bundles ? kanata-tray);
      true;

    # 8. kanata-tray without autostart
    kanata-tray-no-autostart =
      let
        eval = evalWith {
          services.kanata.enable = true;
          services.kanata.kanata-tray.enable = true;
          services.kanata.kanata-tray.autostart = false;
        };
      in
      assert assertionsPass eval;
      assert !(eval.config.services.darwin-smapp.bundles ? kanata-tray);
      assert !(eval.config.launchd.user.agents ? kanata-tray);
      true;

    # 9. daemon + sudoers (default)
    daemon-sudoers =
      let
        eval = evalWith {
          services.kanata.enable = true;
          services.kanata.daemon.enable = true;
        };
      in
      assert assertionsPass eval;
      # user agent via sudo
      assert eval.config.launchd.user.agents ? kanata;
      assert !(eval.config.launchd.daemons ? kanata);
      # sudoers entry present
      assert lib.hasInfix "NOPASSWD" eval.config.security.sudo.extraConfig;
      # no TCC hack warning
      assert eval.config.warnings == [ ];
      true;

    # 10. daemon + no sudoers (TCC hack)
    daemon-tcc-hack =
      let
        eval = evalWith {
          services.kanata.enable = true;
          services.kanata.daemon.enable = true;
          services.kanata.sudoers = false;
        };
      in
      assert assertionsPass eval;
      # root daemon
      assert eval.config.launchd.daemons ? kanata;
      assert !(eval.config.launchd.user.agents ? kanata);
      # warning present
      assert lib.length eval.config.warnings > 0;
      assert lib.any (w: lib.hasInfix "TCC" w) eval.config.warnings;
      true;

    # 11-13. Mutual exclusion assertions
    bar-and-tray-conflict =
      let
        eval = evalWith {
          services.kanata.enable = true;
          services.kanata.kanata-bar.enable = true;
          services.kanata.kanata-tray.enable = true;
        };
      in
      assertionFails eval "at most one";

    bar-and-daemon-conflict =
      let
        eval = evalWith {
          services.kanata.enable = true;
          services.kanata.kanata-bar.enable = true;
          services.kanata.daemon.enable = true;
        };
      in
      assertionFails eval "at most one";

    tray-and-daemon-conflict =
      let
        eval = evalWith {
          services.kanata.enable = true;
          services.kanata.kanata-tray.enable = true;
          services.kanata.daemon.enable = true;
        };
      in
      assertionFails eval "at most one";

    # 14-15. configSource
    config-source-symlink =
      let
        eval = evalWith {
          services.kanata.enable = true;
          services.kanata.configSource = "/some/path/kanata.kbd";
        };
      in
      assert assertionsPass eval;
      assert lib.hasInfix "ln -sf" eval.config.system.activationScripts.postActivation.text;
      true;

    config-source-null =
      let
        eval = evalWith {
          services.kanata.enable = true;
        };
      in
      assert assertionsPass eval;
      assert !(lib.hasInfix "ln -sf" eval.config.system.activationScripts.postActivation.text);
      true;

    # 16. sudoers disabled — no sudo config
    sudoers-disabled =
      let
        eval = evalWith {
          services.kanata.enable = true;
          services.kanata.sudoers = false;
        };
      in
      assert assertionsPass eval;
      assert eval.config.security.sudo.extraConfig == "";
      true;

    # 18. extraLaunchdConfig propagated to smapp
    extra-launchd-config-smapp =
      let
        eval = evalWith {
          services.kanata.enable = true;
          services.kanata.kanata-bar.enable = true;
          services.kanata.kanata-bar.extraLaunchdConfig.ThrottleInterval = 5;
        };
      in
      assert assertionsPass eval;
      let
        svc = eval.config.services.darwin-smapp.bundles.kanata-bar.services."com.kanata-bar.agent";
      in
      assert svc.extraPlistKeys.ThrottleInterval == 5;
      true;

    # extraLaunchdConfig propagated to legacy
    extra-launchd-config-legacy =
      let
        eval = evalWith {
          services.kanata.enable = true;
          services.kanata.kanata-bar.enable = true;
          services.kanata.kanata-bar.smapp = false;
          services.kanata.kanata-bar.extraLaunchdConfig.ThrottleInterval = 5;
        };
      in
      assert assertionsPass eval;
      assert eval.config.launchd.user.agents.kanata-bar.serviceConfig.ThrottleInterval == 5;
      true;

    # 19-22. Stale label cleanup
    stale-labels-bar-smapp =
      let
        eval = evalWith {
          services.kanata.enable = true;
          services.kanata.kanata-bar.enable = true;
        };
        text = eval.config.system.activationScripts.postActivation.text;
      in
      # com.kanata-bar.agent is active, should NOT be cleaned
      assert !(lib.hasInfix "com.kanata-bar.agent" (
        # Extract only the stale cleanup part (the for loop)
        let lines = lib.splitString "\n" text;
            cleanupLines = lib.filter (l: lib.hasInfix "launchctl remove" l) lines;
        in lib.concatStringsSep "\n" cleanupLines
      ));
      # com.kanata-bar.launchd IS stale
      assert lib.hasInfix "com.kanata-bar.launchd" text;
      true;

    stale-labels-bar-legacy =
      let
        eval = evalWith {
          services.kanata.enable = true;
          services.kanata.kanata-bar.enable = true;
          services.kanata.kanata-bar.smapp = false;
        };
        text = eval.config.system.activationScripts.postActivation.text;
      in
      # com.kanata-bar.launchd is active
      assert lib.hasInfix "com.kanata-bar.agent" text; # stale
      assert lib.hasInfix "org.kanata.daemon" text; # stale
      true;

    stale-labels-disabled =
      let
        eval = evalWith {
          services.kanata.enable = false;
        };
        text = eval.config.system.activationScripts.postActivation.text;
      in
      # All labels are stale
      assert lib.hasInfix "com.kanata-bar" text;
      assert lib.hasInfix "org.kanata.tray" text;
      assert lib.hasInfix "org.kanata.daemon" text;
      true;

    # Always-on: preActivation kills kanata even when disabled
    pre-activation-always-kills =
      let
        eval = evalWith {
          services.kanata.enable = false;
        };
        text = eval.config.system.activationScripts.preActivation.text;
      in
      assert lib.hasInfix "pkill -KILL -x kanata" text;
      assert lib.hasInfix "pkill -x kanata-tray" text;
      assert lib.hasInfix "pkill -x kanata-bar" text;
      true;
  };

  # Build a single derivation that evaluates all tests
  runTests = pkgs.runCommand "kanata-darwin-tests" { } ''
    echo "Running kanata-darwin evaluation tests..."
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: result: ''
      echo "  ${name}: ${if result then "PASS" else "FAIL"}"
    '') tests)}
    echo "All ${toString (lib.length (lib.attrNames tests))} tests passed."
    touch $out
  '';

in
runTests
