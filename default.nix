{ pkgs ? import <nixpkgs> {}, haskellPackages ? pkgs.haskellPackages, args ? {} }:

let
  quasar-network = haskellPackages.callCabal2nix "quasar-network" ./. args;

in
  if pkgs.lib.inNixShell then quasar-network.env else quasar-network
