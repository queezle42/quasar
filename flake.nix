{
  inputs = {
    nixpkgs.url = github:NixOS/nixpkgs/nixos-unstable;
  };

  outputs = { self, nixpkgs }:
  with nixpkgs.lib;
  let
    systems = platforms.unix;
    forAllSystems = genAttrs systems;
    getHaskellPackages = pkgs: pattern: pipe pkgs.haskell.packages [
      attrNames
      (filter (x: !isNull (strings.match pattern x)))
      (sort (x: y: x>y))
      (map (x: pkgs.haskell.packages.${x}))
      head
    ];
  in {
    packages = forAllSystems (system:
      let
        pkgs = import nixpkgs { inherit system; overlays = [ self.overlays.default ]; };
        haskellPackages = getHaskellPackages pkgs "ghc94.";
        results = {
          precise-side-effects = haskellPackages.precise-side-effects;
          quasar = haskellPackages.quasar;
          quasar-examples = haskellPackages.quasar-examples;
          quasar-mqtt = haskellPackages.quasar-mqtt;
          quasar-timer = haskellPackages.quasar-timer;
          quasar-web = haskellPackages.quasar-web;
          quasar-web-client = pkgs.quasar-web-client;
        };
      in results // {
        default = pkgs.linkFarm "quasar-all" (results // mapAttrs' (k: v: nameValuePair "${k}-doc" (v.doc or pkgs.emptyDirectory)) results);
      }
    );

    overlays.default = final: prev: {
      haskell = prev.haskell // {
        packageOverrides = hfinal: hprev: prev.haskell.packageOverrides hfinal hprev // {
          precise-side-effects = hfinal.callCabal2nix "precise-side-effects" ./precise-side-effects {};
          quasar = hfinal.callCabal2nix "quasar" ./quasar {};
          quasar-examples = hfinal.callCabal2nix "quasar-examples" ./examples {};
          quasar-mqtt = hfinal.callCabal2nix "quasar-mqtt" ./quasar-mqtt {};
          quasar-timer = hfinal.callCabal2nix "quasar-timer" ./quasar-timer {};
          quasar-web =
            let srcWithClient = final.runCommand "quasar-web-with-client" {} ''
              mkdir $out
              cp -r ${./quasar-web}/* $out
              chmod +w $out/data
              ln -s ${final.quasar-web-client} $out/data/quasar-web-client
            '';
            in hfinal.callCabal2nix "quasar-web" srcWithClient {};
        };
      };
      quasar-web-client = final.callPackage ./quasar-web-client {};
    };

    devShells = forAllSystems (system:
      let
        pkgs = import nixpkgs { inherit system; overlays = [
          self.overlays.default
          (final: prev: {
            quasar-web-client = final.emptyDirectory;
          })
        ]; };
        haskellPackages = getHaskellPackages pkgs "ghc94.";
      in rec {
        default = haskellPackages.shellFor {
          packages = hpkgs: [
            hpkgs.precise-side-effects
            hpkgs.quasar
            hpkgs.quasar-examples
            hpkgs.quasar-mqtt
            hpkgs.quasar-timer
            hpkgs.quasar-web
          ];
          nativeBuildInputs = [
            pkgs.cabal-install
            pkgs.zsh
            pkgs.entr
            pkgs.ghcid
            haskellPackages.haskell-language-server
            pkgs.hlint

            pkgs.nodejs
            pkgs.nodePackages.npm
            pkgs.nodePackages.typescript-language-server
            pkgs.nodePackages.svelte-language-server
          ];
        };
      }
    );
  };
}
