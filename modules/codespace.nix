{ config, lib, pkgs, ... }:

let
  codespace = pkgs.writeShellApplication {
    name = "codespace";
    runtimeInputs = with pkgs; [ docker devcontainer git gh openssh tmux curl jq coreutils gnused ];
    # The flake's checkout, so the launcher can tell which codespace is the
    # one editing this machine — the default for VM_CONTROL.
    text = builtins.replaceStrings [ "@FLAKE_DIR@" ] [ (import ../paths.nix).flakeDir ]
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
    # Shared download cache, bind-mounted into every container. The code-server
    # installer caches into $HOME/.cache, which is container layer, so each new
    # codespace re-fetched the same ~200 MB tarball. Not state: deleting it
    # costs one download.
    "d /persist/codespace/cache 0755 dev users -"
    # Optional: a git identity for containers to push with, when no ssh agent
    # is being forwarded. Holds only that key — never the host keys in
    # /persist/ssh, which are root-owned and useless for git anyway.
    "d /persist/git       0700 dev users -"
  ];
}
