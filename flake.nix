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
    forAllSystems = lib.genAttrs systems;
  in {
    packages = forAllSystems (system:
    let pkgs = import nixpkgs { inherit system; overlays = [
        self.overlay
        quasar.overlay
      ]; };
      in { inherit (pkgs.haskellPackages) quasar-network; }
    );

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
