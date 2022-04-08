{
  inputs = {
    nixpkgs.url = github:NixOS/nixpkgs/nixos-unstable;
    quasar = {
      url = gitlab:jens/quasar?host=git.c3pb.de;
    };
  };

  outputs = { self, nixpkgs, quasar }:
  let
    lib = nixpkgs.lib;
    systems = lib.platforms.unix;
    forAllSystems = lib.genAttrs systems;
  in {
    packages = forAllSystems (system:
      let pkgs = import nixpkgs { inherit system; overlays = [
        self.overlay
        quasar.overlay
      ]; };
      in rec {
        default = quasar-network;
        quasar-network = pkgs.haskell.packages.ghc922.quasar-network;
      }
    );

    overlay = final: prev: {
      haskell = prev.haskell // {
        packageOverrides = hfinal: hprev: prev.haskell.packageOverrides hfinal hprev // {
          quasar-network = import ./. { pkgs = final; haskellPackages = hfinal; };
        };
      };
    };

    overlays.quasar = quasar.overlay;

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
