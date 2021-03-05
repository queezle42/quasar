{ pkgs ? import <nixpkgs> {}, haskellPackages ? pkgs.haskellPackages, args ? {} }:

let
  qrpc = haskellPackages.callCabal2nix "qrpc" ./. args;

in
  if pkgs.lib.inNixShell then qrpc.env else qrpc
