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
    # The path, not `import` of it: importing loses the file provenance, so
    # home-manager's evaluation warnings get blamed on this file instead of the
    # one that actually sets the option.
    users.dev = ../home/dev.nix;
  };

  # GitHub's host keys, scanned once on the VM and shared with every container
  # through the /persist/git mount. Without this a container cloning over SSH
  # has nothing to verify github.com against, and the clone either prompts (and
  # fails, being non-interactive) or has to trust blindly every single time.
  #
  # Best-effort: no network at boot must not fail the unit, and containers still
  # carry StrictHostKeyChecking=accept-new as a fallback.
  systemd.services.github-known-hosts = {
    description = "Record GitHub's SSH host keys for containers to verify against";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    unitConfig.RequiresMountsFor = "/persist/git";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = with pkgs; [ openssh coreutils ];
    script = ''
      out=/persist/git/known_hosts
      [ -s "$out" ] && exit 0

      if ssh-keyscan -t rsa,ecdsa,ed25519 github.com > "$out".tmp 2>/dev/null          && [ -s "$out".tmp ]; then
        mv "$out".tmp "$out"
        chown dev:users "$out"
        chmod 0644 "$out"
      else
        rm -f "$out".tmp
        echo "could not reach github.com to scan host keys; containers will"
        echo "fall back to accept-new on first connection"
      fi
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
