{
  outputs = { self, nixpkgs }:
  let
    lib = nixpkgs.lib;
    systems = lib.platforms.unix;
    forAllSystems = f: lib.genAttrs systems (system: f system);
  in {
    packages = forAllSystems (system: {
      qrpc = import ./. {
        pkgs = nixpkgs.legacyPackages.${system};
      };
    });

    overlay = self: super: {
      haskell = super.haskell // {
        packageOverrides = hself: hsuper: super.haskell.packageOverrides hself hsuper // {
          qrpc = import ./. { pkgs = self; haskellPackages = hself; };
        };
      };
    };

    defaultPackage = forAllSystems (system: self.packages.${system}.qrpc);

    devShell = forAllSystems (system: self.packages.${system}.qrpc.env);
  };
}
