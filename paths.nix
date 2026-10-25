# Where the VM keeps your git identity and key material.
#
# These are *paths*, not values — nothing personal lives in this repo. Your
# name and email go in the identity file below, on /persist, which is neither
# committed nor shared. See "Your git identity" in the README.
#
# Imported by modules/home.nix and modules/tools.nix so the two cannot drift.
{
  keyFile = "/persist/git/id_ed25519";

  # A gitconfig fragment holding [user] name and email. Included by the VM's
  # git config and mounted into containers, so both layers author commits as
  # the same person with one file to edit.
  identityFile = "/persist/git/identity";

  allowedSigners = "/persist/git/allowed_signers";

  # The GitHub App's client ID and secret, and the refresh token
  # github-app-login saves (docs/GITHUB-APP.md). Values only on /persist.
  githubAppDir = "/persist/github-app";

  # The credential services' sockets on the VM (modules/codespace-auth.nix),
  # mounted into codespaces at /mnt/github. The VM's own git and gh ask the
  # token broker here too.
  authDir = "/run/codespace-auth";

  # This repo's working copy, and the flake output built from it.
  flakeDir = "/persist/dev-vm";
  flakeAttr = "dev";
}
