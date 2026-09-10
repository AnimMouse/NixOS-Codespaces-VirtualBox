{ config, lib, pkgs, ... }:

let
  p = import ../paths.nix;

  # The scripts are plain files with @PLACEHOLDERS@ rather than Nix strings, so
  # they stay readable and shellcheck-able on their own. substituteInPlace at
  # build time keeps paths.nix the single source of truth.
  substituted = name: text:
    builtins.replaceStrings
      [ "@FLAKE_DIR@" "@FLAKE_ATTR@" "@KEY_FILE@" ]
      [ p.flakeDir p.flakeAttr p.keyFile ]
      text;

  rebuild = pkgs.writeShellApplication {
    name = "rebuild";
    runtimeInputs = with pkgs; [ git nixos-rebuild ];
    text = substituted "rebuild" (builtins.readFile ../scripts/rebuild);
  };

  ssh-auth = pkgs.writeShellApplication {
    name = "ssh-auth";
    runtimeInputs = with pkgs; [ openssh gawk gnugrep ];
    text = substituted "ssh-auth" (builtins.readFile ../scripts/ssh-auth);
  };
in
{
  environment.systemPackages = [ rebuild ssh-auth ];
}
