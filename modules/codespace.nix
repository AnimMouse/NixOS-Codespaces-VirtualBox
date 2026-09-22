{ config, lib, pkgs, ... }:

let
  # The devcontainer CLI cannot publish a port on a container it creates: `up`
  # has no --publish, and appPort/runArgs only exist inside a project's own
  # devcontainer.json, which must stay portable to real Codespaces. So the
  # editor is reached through a small TCP proxy on the VM. The container's
  # bridge address is resolved at start time rather than baked in, because it
  # changes whenever the container is recreated.
  codespace-proxy = pkgs.writeShellApplication {
    name = "codespace-proxy";
    runtimeInputs = with pkgs; [ docker socat coreutils ];
    text = ''
      name="$1"
      port_file="/persist/codespace/$name/port"
      [ -r "$port_file" ] || { echo "no port allocated for '$name'" >&2; exit 1; }
      port=$(cat "$port_file")

      cid=$(docker ps -q --filter "label=codespace=$name" | head -1)
      [ -n "$cid" ] || { echo "no running container for '$name'" >&2; exit 1; }

      ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$cid")
      [ -n "$ip" ] || { echo "container '$name' has no address" >&2; exit 1; }

      echo "proxying 0.0.0.0:$port -> $ip:8080 ($name)"
      exec socat "TCP-LISTEN:$port,fork,reuseaddr" "TCP:$ip:8080"
    '';
  };

  codespace = pkgs.writeShellApplication {
    name = "codespace";
    runtimeInputs = with pkgs; [ docker devcontainer git gh openssh tmux curl jq coreutils gnused ];
    text = builtins.readFile ../scripts/codespace;
  };
in
{
  environment.systemPackages = [ codespace ];

  # A template unit rather than something the launcher spawns by hand, so the
  # proxies are visible to systemctl, restart on failure, and die cleanly with
  # `codespace down`.
  systemd.services."codespace-proxy@" = {
    description = "code-server proxy for codespace %i";
    after = [ "docker.service" ];
    requires = [ "docker.service" ];
    # No start rate limit. This unit legitimately fails when its container is
    # not up yet, and systemd's default (5 starts per 10s) then parks it in a
    # failed state where `systemctl restart` is refused until `reset-failed` —
    # which presents as the editor never answering, with nothing wrong with the
    # editor.
    unitConfig.StartLimitIntervalSec = 0;

    serviceConfig = {
      ExecStart = "${lib.getExe codespace-proxy} %i";
      Restart = "on-failure";
      RestartSec = 5;
      DynamicUser = false;
    };
  };

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
    # Optional: a git identity for containers to push with, when no ssh agent
    # is being forwarded. Holds only that key — never the host keys in
    # /persist/ssh, which are root-owned and useless for git anyway.
    "d /persist/git       0700 dev users -"
  ];
}
