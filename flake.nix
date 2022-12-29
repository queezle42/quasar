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
      in rec {
        default = quasar_ghc92;
        quasar = pkgs.haskellPackages.quasar;
        quasar_ghc92 = (getHaskellPackages pkgs "ghc92.").quasar;
        quasar_ghc94 = (getHaskellPackages pkgs "ghc94.").quasar;
        quasar-timer = pkgs.haskellPackages.quasar-timer;
        quasar-timer_ghc92 = (getHaskellPackages pkgs "ghc92.").quasar-timer;
        stm-ltd = (getHaskellPackages pkgs "ghc94.").stm-ltd;
      }
    );

    overlays.default = final: prev: {
      haskell = prev.haskell // {
        packageOverrides = hfinal: hprev: prev.haskell.packageOverrides hfinal hprev // {
          quasar = hfinal.callCabal2nix "quasar" ./quasar {};
          quasar-timer = hfinal.callCabal2nix "quasar-timer" ./quasar-timer {};
          stm-ltd = hfinal.callCabal2nix "stm-ltd" ./stm-ltd {};
          # Due to a ghc bug in 9.4.3 and 9.2.5
          ListLike = final.haskell.lib.dontCheck hprev.ListLike;
        };
      };
    };

    devShells = forAllSystems (system:
      let
        pkgs = import nixpkgs { inherit system; overlays = [ self.overlays.default ]; };
        haskellPackages = getHaskellPackages pkgs "ghc92.";
      in rec {
        default = haskellPackages.shellFor {
          packages = hpkgs: [
            hpkgs.quasar
            hpkgs.quasar-timer
            hpkgs.stm-ltd
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
