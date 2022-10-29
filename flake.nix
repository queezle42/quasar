{
  inputs = {
    nixpkgs.url = github:NixOS/nixpkgs/nixos-unstable;
  };

  outputs = { self, nixpkgs }:
  with nixpkgs.lib;
  let
    systems = platforms.unix;
    forAllSystems = genAttrs systems;
  in {
    packages = forAllSystems (system:
      let
        pkgs = import nixpkgs { inherit system; overlays = [ self.overlays.default ]; };
        getHaskellPackages = pattern: pipe pkgs.haskell.packages [
          attrNames
          (filter (x: !isNull (strings.match pattern x)))
          (sort (x: y: x>y))
          (map (x: pkgs.haskell.packages.${x}))
          head
        ];
      in rec {
        default = quasar_ghc92;
        quasar = pkgs.haskellPackages.quasar;
        quasar_ghc92 = (getHaskellPackages "ghc92.").quasar;
        quasar_ghc94 = (getHaskellPackages "ghc94.").quasar;
        quasar-timer = pkgs.haskellPackages.quasar-timer;
        quasar-timer_ghc92 = (getHaskellPackages "ghc92.").quasar-timer;
        stm-ltd = (getHaskellPackages "ghc92.").stm-ltd;
      }
    );

    overlays.default = final: prev: {
      haskell = prev.haskell // {
        packageOverrides = hfinal: hprev: prev.haskell.packageOverrides hfinal hprev // {
          quasar = hfinal.callCabal2nix "quasar" ./quasar {};
          quasar-timer = hfinal.callCabal2nix "quasar-timer" ./quasar-timer {};
          stm-ltd = hfinal.callCabal2nix "stm-ltd" ./stm-ltd {};
        };
      };
    };

    devShells = forAllSystems (system:
      let
        pkgs = import nixpkgs { inherit system; overlays = [ self.overlays.default ]; };
        getHaskellPackages = pattern: pipe pkgs.haskell.packages [
          attrNames
          (filter (x: !isNull (strings.match pattern x)))
          (sort (x: y: x>y))
          (map (x: pkgs.haskell.packages.${x}))
          head
        ];
        haskellPackages = getHaskellPackages "ghc92.";
      in rec {
        # Using quasar-timer because it encompasses all dependencies.
        # A better solution could be built using `shellFor`
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
            pkgs.haskell-language-server
            pkgs.hlint
          ];
        };
      }
    );
  };
}
