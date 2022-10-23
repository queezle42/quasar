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
        pkgs = nixpkgs.legacyPackages.${system};
        mkShellFor = pkg: pkgs.mkShell {
          inputsFrom = [ pkg ];
          packages = [
            pkgs.cabal-install
            pkgs.zsh
            pkgs.entr
            pkgs.ghcid
            pkgs.haskell-language-server
            pkgs.hlint
          ];
        };
      in rec {
        # Using quasar-timer because it encompasses all dependencies.
        # A better solution could be built using `shellFor`
        default = mkShellFor self.packages.${system}.quasar-timer_ghc92.env;
        stm-ltd = mkShellFor self.packages.${system}.stm-ltd.env;
      }
    );
  };
}
