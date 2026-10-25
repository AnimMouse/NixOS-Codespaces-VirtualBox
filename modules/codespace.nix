{ config, lib, pkgs, ... }:

let
  codespace = pkgs.writeShellApplication {
    name = "codespace";
    runtimeInputs = with pkgs; [ docker devcontainer git gh openssh tmux curl jq coreutils gnused diffutils gnutar gzip e2fsprogs util-linux ];
    # The flake's checkout, so the launcher can tell which codespace is the
    # one editing this machine — the default for VM_CONTROL. And the default
    # devcontainer.json, from the store, so the template is versioned with the
    # launcher that copies it.
    text = builtins.replaceStrings
      [ "@FLAKE_DIR@" "@TEMPLATE@" ]
      [ (import ../paths.nix).flakeDir "${../templates/devcontainer.json}" ]
      (builtins.readFile ../scripts/codespace);
  };
in
{
  environment.systemPackages = [ codespace ];

  # Retention, the way real Codespaces does it: a container left idle past
  # RETENTION_DAYS (default 30, from /persist/codespace/config) is removed.
  #
  # This lives here rather than in Docker's autoPrune because autoPrune cannot
  # express it. Its only filter, `until`, matches container *creation* time, so
  # it would reap a codespace you use daily simply for having existed a month —
  # which is exactly what it was doing. modules/docker.nix now exempts anything
  # labelled `codespace` from the prune, and the clock lives here instead.
  systemd.services.codespace-gc = {
    description = "Remove dev containers idle past the retention window";
    after = [ "docker.service" ];
    requires = [ "docker.service" ];
    serviceConfig = {
      Type = "oneshot";
      # Not root. `dev` is in the docker group and owns /persist/codespace, so
      # the sweep needs nothing the launcher does not already have — and a
      # mistake in it can reach no further than the launcher could.
      User = "dev";
      ExecStart = "${lib.getExe codespace} gc";
    };
    # sudo, for removing code-server versions nothing uses: they are immutable,
    # and only root can lift that. Units get no /run/wrappers on their PATH.
    path = [ "/run/wrappers" ];
  };

  systemd.timers.codespace-gc = {
    description = "Daily codespace retention sweep";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      # The VM is not up around the clock, so without this a sweep due while it
      # was off is simply skipped and containers age indefinitely.
      Persistent = true;
      # Nothing races this, but it keeps the sweep off the same instant as
      # every other daily unit on a machine with one disk.
      RandomizedDelaySec = "15m";
    };
  };

  systemd.tmpfiles.rules = [
    "d /persist/codespace 0755 dev users -"
    # Reference checkouts, mounted into every container at /workspaces/refs.
    # In real Codespaces /workspaces is itself persistent, so cloning a repo
    # next to your project for reference just works; here only the project is a
    # mount, so this is the equivalent that survives.
    "d /persist/refs      0755 dev users -"
    # Optional: a git identity for containers to push with, when no ssh agent
    # is being forwarded. Holds only that key — never the host keys in
    # /persist/ssh, which are root-owned and useless for git anyway.
    "d /persist/git       0700 dev users -"
  ];
}
