# kanata-darwin

Declarative [nix-darwin](https://github.com/LnL7/nix-darwin) module for [kanata](https://github.com/jtroo/kanata) keyboard remapper on macOS.

Handles everything needed to run kanata on macOS:
- Installs and activates the [Karabiner DriverKit VirtualHIDDevice](https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice) (required for HID on macOS)
- Configures launchd services, sudoers, and TCC permissions
- Optionally integrates [kanata-tray](https://github.com/rszyma/kanata-tray) GUI with a macOS .app bundle

## Usage

Add to your flake inputs:

```nix
{
  inputs = {
    kanata-darwin = {
      url = "github:not-in-stock/kanata-darwin";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
}
```

Include the module in your darwin configuration:

```nix
modules = [
  inputs.kanata-darwin.darwinModules.default
  # ...
];
```

Minimal configuration:

```nix
services.kanata = {
  enable = true;
  configSource = ./kanata.kbd;  # symlinked to configFile path
};
```

## Options

All options are under `services.kanata`.

| Option | Type | Default | Description |
|---|---|---|---|
| `enable` | bool | `false` | Enable kanata with Karabiner DriverKit |
| `mode` | `"daemon"` \| `"tray"` | `"tray"` | Launch mode (see below) |
| `sudoers` | bool | `true` for daemon, `false` for tray | Add NOPASSWD sudoers entry |
| `user` | string | `system.primaryUser` | Username for file paths, sudoers, and user agents |
| `configFile` | string | `~/Library/Application Support/kanata/kanata.kbd` | Path to kanata config |
| `configSource` | path \| null | `null` | If set, `configFile` is symlinked to this path |
| `package` | package | `pkgs.kanata-with-cmd` | The kanata package |
| `tray.package` | package | from kanata-tray flake | The kanata-tray package |
| `tray.autostart` | bool | `true` | Create a launchd agent to start kanata-tray at login |
| `tray.settings` | TOML attrs | `{}` | Extra settings merged into `kanata-tray.toml` |

## Modes

The `mode` and `sudoers` options combine into four configurations:

| mode | sudoers | How it works |
|---|---|---|
| `tray` | `false` (default) | kanata-tray launches kanata via sudo; prompts for TouchID/password each start |
| `tray` | `true` | Same, but with NOPASSWD — no prompts |
| `daemon` | `true` (default) | Headless user launchd agent via sudo NOPASSWD; one-time TCC dialog |
| `daemon` | `false` | Root launchd daemon with TCC sqlite3 hack (fragile, not recommended) |

> [!CAUTION]
> `daemon` + `sudoers = false` uses a sqlite3 hack to write directly to the macOS TCC database for Input Monitoring permission. Apple may change the TCC.db schema in future macOS updates, which would silently break kanata or corrupt the database. Prefer `sudoers = true` (default) or `mode = "tray"` instead.

## First activation

On the first `darwin-rebuild switch`, macOS will show a system dialog asking to allow the Karabiner DriverKit extension. Approve it once — subsequent activations are silent.

## Karabiner driver

The module automatically installs the Karabiner DriverKit VirtualHIDDevice package and starts its daemon via launchd. The driver pkg is installed outside the Nix store because macOS rejects code signatures from store paths.
