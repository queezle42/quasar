{
  inputs = {
    quasar = {
      url = gitlab:jens/quasar?host=git.c3pb.de;
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, quasar }:
  let
    lib = nixpkgs.lib;
    systems = lib.platforms.unix;
    forAllSystems = f: lib.genAttrs systems (system: f system);
  in {
    packages = forAllSystems (system: {
      quasar-network = import ./. {
        pkgs = import nixpkgs { inherit system; overlays = [ quasar.overlay ]; };
      };
    });

    overlay = self: super: {
      haskell = super.haskell // {
        packageOverrides = hself: hsuper: super.haskell.packageOverrides hself hsuper // {
          quasar-network = import ./. { pkgs = self; haskellPackages = hself; };
        };
      };
    };

    overlays.quasar = quasar.overlay;

    defaultPackage = forAllSystems (system: self.packages.${system}.quasar-network);

    devShell = forAllSystems (system: self.packages.${system}.quasar-network.env);
  };
}
