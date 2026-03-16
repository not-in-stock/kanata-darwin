{
  description = "Declarative configuration module for kanata keyboard remapper for macOS (nix-darwin)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    kanata-tray = {
      url = "github:rszyma/kanata-tray";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    darwin-smapp = {
      url = "github:not-in-stock/darwin-smapp";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      kanata-tray,
      darwin-smapp,
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
      darwinModules.default = import ./module.nix { inherit kanata-tray darwin-smapp; };

      lib.mkLayerIcons =
        pkgs:
        { font, labels }:
        let
          iconsPkg = pkgs.runCommand "kanata-layer-icons"
            { nativeBuildInputs = [ pkgs.imagemagick font ]; }
            ''
              mkdir -p $out
              FONT=$(find ${font} -name '*.ttf' -o -name '*.otf' | head -1)
              if [ -z "$FONT" ]; then
                echo "error: no TTF/OTF font found in ${font}" >&2
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

              ${nixpkgs.lib.concatStringsSep "\n" (nixpkgs.lib.mapAttrsToList (
                name: label:
                "gen_icon ${nixpkgs.lib.escapeShellArg name} ${nixpkgs.lib.escapeShellArg label}"
              ) labels)}
            '';
        in
        nixpkgs.lib.mapAttrs (name: _: "${iconsPkg}/${name}.png") labels;

      # Module tests require darwin packages (apple-sdk, etc.)
      checks = nixpkgs.lib.genAttrs [ "aarch64-darwin" "x86_64-darwin" ] (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          module-tests = import ./tests {
            inherit pkgs kanata-tray darwin-smapp;
          };
        }
      );

      packages = forDocsSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          docs = import ./doc {
            inherit pkgs kanata-tray darwin-smapp;
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
