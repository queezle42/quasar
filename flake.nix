{
  outputs = { self, nixpkgs }:
  with nixpkgs.lib;
  let
    forAllSystems = genAttrs ["x86_64-linux" "aarch64-linux"];
    pkgs = forAllSystems (system: import nixpkgs { inherit system; overlays = [ self.overlay ]; });
  in {

    devShell = forAllSystems (system: pkgs.${system}.haskellPackages.quasar.env);

    defaultPackage = forAllSystems (system: pkgs.${system}.haskellPackages.quasar);

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

  };
}
