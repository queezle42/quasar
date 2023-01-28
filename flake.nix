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
          quasar-mqtt = haskellPackages.quasar-mqtt;
          quasar-timer = haskellPackages.quasar-timer;
        };
      in results // {
        default = pkgs.linkFarm "quasar-all" (results // mapAttrs' (k: v: nameValuePair "${k}-doc" v.doc) results);
      }
    );

    overlays.default = final: prev: {
      haskell = prev.haskell // {
        packageOverrides = hfinal: hprev: prev.haskell.packageOverrides hfinal hprev // {
          precise-side-effects = hfinal.callCabal2nix "precise-side-effects" ./precise-side-effects {};
          quasar = hfinal.callCabal2nix "quasar" ./quasar {};
          quasar-mqtt = hfinal.callCabal2nix "quasar-mqtt" ./quasar-mqtt {};
          quasar-timer = hfinal.callCabal2nix "quasar-timer" ./quasar-timer {};
          # Due to a ghc bug in 9.4.3 and 9.2.5
          ListLike = final.haskell.lib.dontCheck hprev.ListLike;
          net-mqtt = final.haskell.lib.doJailbreak hprev.net-mqtt;
        };
      };
    };

    devShells = forAllSystems (system:
      let
        pkgs = import nixpkgs { inherit system; overlays = [ self.overlays.default ]; };
        haskellPackages = getHaskellPackages pkgs "ghc94.";
      in rec {
        default = haskellPackages.shellFor {
          packages = hpkgs: [
            hpkgs.precise-side-effects
            hpkgs.quasar
            hpkgs.quasar-mqtt
            hpkgs.quasar-timer
          ];
          nativeBuildInputs = [
            pkgs.cabal-install
            pkgs.zsh
            pkgs.entr
            pkgs.ghcid
            haskellPackages.haskell-language-server
            pkgs.hlint
          ];
        };
      }
    );
  };
}
