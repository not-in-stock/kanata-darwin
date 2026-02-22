{
  pkgs,
  kanata-tray,
  revision ? "main",
}:

let
  lib = pkgs.lib;

  # Evaluate the module to extract options
  eval = lib.evalModules {
    modules = [
      (import ../module.nix { inherit kanata-tray; })
      {
        _module.args = { inherit pkgs; };
        _module.check = false;
      }
      {
        options.system.primaryUser = lib.mkOption {
          type = lib.types.str;
          default = "user";
          internal = true;
        };
      }
    ];
  };

  # Generate GitHub declaration links
  gitHubDeclaration = subpath: {
    url = "https://github.com/not-in-stock/kanata-darwin/blob/${revision}/${subpath}";
    name = "<kanata-darwin/${subpath}>";
  };

  # Generate options documentation
  optionsDoc = pkgs.buildPackages.nixosOptionsDoc {
    options = eval.options;
    transformOptions =
      opt:
      opt
      // {
        declarations = map (
          decl:
          let
            declStr = toString decl;
            prefix = toString ./..;
          in
          if lib.hasPrefix prefix declStr then
            gitHubDeclaration (lib.removePrefix "/" (lib.removePrefix prefix declStr))
          else
            decl
        ) opt.declarations;
      };
  };

in
rec {
  # JSON with all options
  optionsJSON =
    pkgs.runCommand "options.json"
      { meta.description = "List of kanata-darwin options in JSON format"; }
      ''
        mkdir -p $out/share/doc/kanata-darwin
        cp -a ${optionsDoc.optionsJSON}/share/doc/nixos/options.json \
          $out/share/doc/kanata-darwin/options.json
      '';

  # HTML manual
  manualHTML =
    pkgs.runCommand "kanata-darwin-manual"
      {
        nativeBuildInputs = [ pkgs.buildPackages.nixos-render-docs ];
        styles = lib.sourceFilesBySuffices (pkgs.path + "/doc") [ ".css" ];
        meta.description = "kanata-darwin manual in HTML format";
        allowedReferences = [ "out" ];
      }
      ''
        dst=$out/share/doc/kanata-darwin
        mkdir -p $dst

        cp $styles/style.css $dst
        cp -r ${pkgs.documentation-highlighter} $dst/highlightjs

        substitute ${./manual.md} manual.md \
          --replace-fail \
            '@OPTIONS_JSON@' \
            ${optionsJSON}/share/doc/kanata-darwin/options.json

        nixos-render-docs -j $NIX_BUILD_CORES manual html \
          --manpage-urls ${pkgs.writeText "manpage-urls.json" "{}"} \
          --revision ${lib.escapeShellArg revision} \
          --generator "nixos-render-docs" \
          --stylesheet style.css \
          --stylesheet highlightjs/mono-blue.css \
          --script ./highlightjs/highlight.pack.js \
          --script ./highlightjs/loader.js \
          --toc-depth 1 \
          --chunk-toc-depth 1 \
          ./manual.md \
          $dst/index.html
      '';

  # Standalone HTML directory for GitHub Pages
  htmlDocs =
    pkgs.runCommand "kanata-darwin-docs" { }
      ''
        cp -r ${manualHTML}/share/doc/kanata-darwin $out
      '';
}
