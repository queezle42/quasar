{
  outputs = { self, nixpkgs }:
  with nixpkgs.lib;
  let
    systems = platforms.unix;
    forAllSystems = genAttrs systems;
  in {
    packages = forAllSystems (system:
      let pkgs = import nixpkgs { inherit system; overlays = [ self.overlay ]; };
      in { quasar = pkgs.haskellPackages.quasar; }
    );

    overlay = final: prev: {
      haskell = prev.haskell // {
        packageOverrides = hfinal: hprev: prev.haskell.packageOverrides hfinal hprev // {
          quasar = import ./. {
            pkgs = final;
            haskellPackages = hfinal;
          };
        };
      };
    };

    defaultPackage = forAllSystems (system: self.packages.${system}.quasar);

    devShell = forAllSystems (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in pkgs.mkShell {
        inputsFrom = pkgs.lib.mapAttrsToList (k: v: v.env or v) self.packages.${system};
        packages = [
          pkgs.cabal-install
          pkgs.ghcid
          pkgs.haskell-language-server
        ];
      }
    );
  };
}
