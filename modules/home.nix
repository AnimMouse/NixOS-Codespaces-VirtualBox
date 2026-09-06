{ config, lib, pkgs, ... }:

let
  # One identity, defined once. The VM's own git config (home/dev.nix) and the
  # allowed_signers generator below both read it, so they cannot drift apart.
  gitIdentity = {
    name = "Anim Mouse";
    email = "git@animmouse.com";
    # One key, two jobs: GitHub accepts the same public key registered both as
    # an Authentication key and as a Signing key. It lives on /persist so it
    # survives a system.vdi wipe, and modules/codespace.nix mounts the same
    # directory into dev containers — so the VM and its containers sign and
    # push with the same key.
    keyFile = "/persist/git/id_ed25519";
    allowedSigners = "/persist/git/allowed_signers";
  };
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
    users.dev = import ../home/dev.nix;
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
    path = with pkgs; [ coreutils ];
    script = ''
      pub="${gitIdentity.keyFile}.pub"
      out="${gitIdentity.allowedSigners}"

      if [ ! -r "$pub" ]; then
        echo "no public key at $pub yet — signature verification will not work"
        echo "until one exists. See 'GitHub authentication' in the README."
        exit 0
      fi

      printf '%s namespaces="git" %s\n' "${gitIdentity.email}" "$(cat "$pub")" > "$out"
      chown dev:users "$out"
      chmod 0644 "$out"
    '';
  };
}
