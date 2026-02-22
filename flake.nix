{
  description = "Declarative configuration module for kanata keyboard remapper for macOS (nix-darwin)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    kanata-tray = {
      url = "github:rszyma/kanata-tray";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      kanata-tray,
      ...
    }:
    {
      darwinModules.default = import ./module.nix { inherit kanata-tray; };
    };
}
