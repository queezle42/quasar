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
        pkgs = import nixpkgs { inherit system; overlays = [ self.overlay ]; };
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
        stm-ltd = pkgs.haskellPackages.stm-ltd;
      }
    );

    overlay = final: prev: {
      haskell = prev.haskell // {
        packageOverrides = hfinal: hprev: prev.haskell.packageOverrides hfinal hprev // {
          stm-ltd = hfinal.callCabal2nix "stm-ltd" ./stm-ltd {};
          quasar = hfinal.callCabal2nix "quasar" ./quasar {};
        };
      };
    };

    devShell = forAllSystems (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in pkgs.mkShell {
        inputsFrom = [
          self.packages.${system}.quasar.env
          self.packages.${system}.stm-ltd.env
        ];
        packages = [
          pkgs.cabal-install
          pkgs.zsh
          pkgs.entr
          pkgs.ghcid
          pkgs.haskell-language-server
          pkgs.hlint
        ];
      }
    );
  };
}
