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
      let pkgs = import nixpkgs { inherit system; overlays = [ self.overlay ]; };
      in rec {
        default = ghc924.quasar;
        quasar = pkgs.haskellPackages.quasar;
        ghc924.quasar = pkgs.haskell.packages.ghc924.quasar;
        ghc941.quasar = pkgs.haskell.packages.ghc941.quasar;
      }
    );

    overlay = final: prev: {
      haskell = prev.haskell // {
        packageOverrides = hfinal: hprev: prev.haskell.packageOverrides hfinal hprev // {
          quasar = hfinal.callCabal2nix "quasar" ./. {};
        };
      };
    };

    devShell = forAllSystems (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in pkgs.mkShell {
        inputsFrom = [ self.packages.${system}.default.env ];
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
