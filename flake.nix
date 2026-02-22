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
    let
      # Systems that can build documentation (includes Linux for CI)
      docsSystems = [
        "aarch64-darwin"
        "x86_64-darwin"
        "x86_64-linux"
        "aarch64-linux"
      ];

      forDocsSystems = nixpkgs.lib.genAttrs docsSystems;
    in
    {
      darwinModules.default = import ./module.nix { inherit kanata-tray; };

      packages = forDocsSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          docs = import ./doc {
            inherit pkgs kanata-tray;
            revision = self.rev or self.dirtyRev or "main";
          };
        in
        {
          docs = docs.htmlDocs;
          options-json = docs.optionsJSON;
        }
      );
    };
}
