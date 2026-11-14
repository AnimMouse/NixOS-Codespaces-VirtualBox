{ config, lib, pkgs, ... }:

let
  # Paths only. Your name and email are NOT here: they live in a gitconfig
  # fragment at gitIdentity.identityFile, on /persist, which this repo never
  # sees. That keeps one editable file for both the VM and its containers, and
  # keeps a personal identity out of a public repo.
  #
  # One key, two jobs: GitHub accepts the same public key registered both as an
  # Authentication key and as a Signing key. It lives on /persist so it survives
  # a system.vdi wipe, and the launcher gives containers access to the same one.
  gitIdentity = import ../paths.nix;
in
{
  # The VM layer of dotfiles (CLAUDE.md §6). The container layer is a separate
  # plain-bash repo and deliberately not Nix, because it has to work in real
  # Codespaces and in any random container too.
  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    # Move anything home-manager would clobber aside instead of failing the
    # activation — otherwise the first switch dies on files left behind by the
    # image or by hand.
    backupFileExtension = "hm-bak";

    extraSpecialArgs = { inherit gitIdentity; };
    # The path, not `import` of it: importing loses the file provenance, so
    # home-manager's evaluation warnings get blamed on this file instead of the
    # one that actually sets the option.
    users.dev = ../home/dev.nix;
  };

  # Without lingering, /run/user/1000 and everything in it — the ssh-agent
  # included — is torn down when the last session ends, and containers holding
  # a mount to the agent socket break until the next login.
  users.users.dev.linger = true;

  # Created empty-but-explained on first boot, so a fresh VM has an obvious file
  # to edit rather than a path someone has to read the README to discover.
  #
  # Deliberately no values, not even placeholders: git ignores a comments-only
  # include, so an unedited VM has no identity and says "please tell me who you
  # are" on the first commit — far better than quietly authoring everything as
  # "Your Name". The comments carry the commands that work, because git's own
  # advice (`git config --global ...`) cannot: home-manager owns
  # ~/.config/git/config as a symlink into the read-only store, so that write
  # fails with "could not lock config file".
  systemd.services.git-identity-template = {
    description = "Seed an empty git identity file for the user to fill in";
    wantedBy = [ "multi-user.target" ];
    unitConfig.RequiresMountsFor = "/persist/git";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = with pkgs; [ coreutils ];
    script = ''
      out="${gitIdentity.identityFile}"
      [ -e "$out" ] && exit 0

      mkdir -p "$(dirname "$out")"
      cat > "$out" <<'TEMPLATE'
# Your git identity — the one place the VM and every dev container read it from.
#
# Set it with:
#     git config -f ${gitIdentity.identityFile} user.name  "Your Name"
#     git config -f ${gitIdentity.identityFile} user.email you@example.com
#
# or just uncomment and edit the two lines below.
#
# `git config --global ...` will NOT work: ~/.config/git/config is managed by
# home-manager and is a read-only symlink into the nix store.
#
# While this file has no user.name/user.email, git will ask who you are on your
# first commit. That is intentional — better than committing as a placeholder.

#[user]
#	name = Your Name
#	email = you@example.com
TEMPLATE

      chown dev:users "$out"
      chmod 0644 "$out"
      echo "wrote an empty identity template to $out"
    '';
  };

  # allowed_signers is derived from the key rather than appended to. The
  # Codespaces dotfiles used `>>` on every login, which grows the file without
  # bound and fills it with duplicates; rewriting it from the key each boot
  # cannot drift.
  systemd.services.git-allowed-signers = {
    description = "Derive allowed_signers from the git signing key";
    wantedBy = [ "multi-user.target" ];
    unitConfig.RequiresMountsFor = "/persist/git";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = with pkgs; [ coreutils git ];
    script = ''
      pub="${gitIdentity.keyFile}.pub"
      out="${gitIdentity.allowedSigners}"

      if [ ! -r "$pub" ]; then
        echo "no public key at $pub yet — signature verification will not work"
        echo "until one exists. See 'GitHub authentication' in the README."
        exit 0
      fi

      # Read at runtime rather than baked in at build time, so the identity
      # file stays the only place your email is written down.
      email=$(git config -f "${gitIdentity.identityFile}" --get user.email 2>/dev/null || true)
      if [ -z "$email" ]; then
        echo "no user.email in ${gitIdentity.identityFile} — signatures cannot be"
        echo "verified until it is set. See 'Your git identity' in the README."
        exit 0
      fi

      printf '%s namespaces="git" %s\n' "$email" "$(cat "$pub")" > "$out"
      chown dev:users "$out"
      chmod 0644 "$out"
    '';
  };
}
