{ callPackage, stdenv, runCommand, node2nix, nodejs }:

let
  src = ./.;

  srcN2N =
    runCommand "quasar-web-client-node2nix" {
      buildInputs = [ node2nix ];
    } ''
      mkdir $out

      ln -s ${src}/* $out

      # Remove default.nix (this file)
      rm $out/default.nix

      cd $out
      node2nix --lock package-lock.json --development --nodejs-18
    '';

  resultN2N = callPackage (import srcN2N) {};

  nodeDependencies = resultN2N.nodeDependencies;

in stdenv.mkDerivation {
  name = "quasar-web-client";
  src = src;
  buildInputs = [ nodejs ];
  buildPhase = ''
    ln -s ${nodeDependencies}/lib/node_modules ./node_modules
    export PATH="${nodeDependencies}/bin:$PATH"

    npm run build
  '';
  installPhase = ''
    cp -r dist $out/
  '';
}
