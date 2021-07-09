{ pkgs ? import <nixpkgs> {}, haskellPackages ? pkgs.haskellPackages, args ? {} }:

let
  drv = haskellPackages.callCabal2nix "quasar" ./. args;

in
  if pkgs.lib.inNixShell then drv.env else drv
