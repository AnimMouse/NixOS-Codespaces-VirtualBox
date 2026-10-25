{ config, lib, pkgs, ... }:

let
  p = import ../paths.nix;

  # The scripts are plain files with @PLACEHOLDERS@ rather than Nix strings, so
  # they stay readable and shellcheck-able on their own. substituteInPlace at
  # build time keeps paths.nix the single source of truth.
  substituted = name: text:
    builtins.replaceStrings
      [ "@FLAKE_DIR@" "@FLAKE_ATTR@" "@KEY_FILE@" "@GITHUB_APP_DIR@" ]
      [ p.flakeDir p.flakeAttr p.keyFile p.githubAppDir ]
      text;

  rebuild = pkgs.writeShellApplication {
    name = "rebuild";
    # The system's own nix, so the no-change build agrees with what
    # nixos-rebuild then evaluates.
    runtimeInputs = with pkgs; [ git nixos-rebuild coreutils config.nix.package ];
    text = substituted "rebuild" (builtins.readFile ../scripts/rebuild);
  };

  ssh-auth = pkgs.writeShellApplication {
    name = "ssh-auth";
    runtimeInputs = with pkgs; [ openssh gawk gnugrep ];
    text = substituted "ssh-auth" (builtins.readFile ../scripts/ssh-auth);
  };
  # The GitHub App's one-time device-flow authorisation (docs/GITHUB-APP.md
  # §4.2). Here beside ssh-auth: both are the "give the VM your credentials"
  # step, run by hand, rarely.
  github-app-login = pkgs.writeShellApplication {
    name = "github-app-login";
    runtimeInputs = with pkgs; [ curl jq coreutils ];
    text = substituted "github-app-login" (builtins.readFile ../scripts/github-app-login);
  };
in
{
  environment.systemPackages = [ rebuild ssh-auth github-app-login ];

  # Holds the app's client secret and refresh token, so dev-only. Created here
  # so a fresh install has it with the right owner before anything is put in.
  systemd.tmpfiles.rules = [
    "d ${p.githubAppDir} 0700 dev users -"
  ];
}
