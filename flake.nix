{
  inputs = {
    nixpkgs.url = github:NixOS/nixpkgs/nixos-unstable;
    quasar.url = github:queezle42/quasar;
  };

  outputs = { self, nixpkgs, quasar }:
  let
    lib = nixpkgs.lib;
    systems = lib.platforms.unix;
    forAllSystems = lib.genAttrs systems;
  in {
    packages = forAllSystems (system:
      let pkgs = import nixpkgs { inherit system; overlays = [
        self.overlays.default
        quasar.overlays.default
      ]; };
      in rec {
        default = quasar-network;
        quasar-network = pkgs.haskell.packages.ghc924.quasar-network;
      }
    );

    overlays = {
      default = final: prev: {
        haskell = prev.haskell // {
          packageOverrides = hfinal: hprev: prev.haskell.packageOverrides hfinal hprev // {
            quasar-network = import ./. { pkgs = final; haskellPackages = hfinal; };
          };
        };
      };

      quasar = quasar.overlay;
    };

    devShell = forAllSystems (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in pkgs.mkShell {
        inputsFrom = pkgs.lib.mapAttrsToList (k: v: v.env or v) self.packages.${system};
        packages = [
          pkgs.cabal-install
          pkgs.zsh
          pkgs.entr
          pkgs.ghcid
          pkgs.haskell-language-server
        ];
      }
    );
  };
}
