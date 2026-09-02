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
    runtimeInputs = with pkgs; [ docker devcontainer git curl coreutils gnused ];
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
    serviceConfig = {
      ExecStart = "${lib.getExe codespace-proxy} %i";
      Restart = "on-failure";
      RestartSec = 2;
      DynamicUser = false;
    };
  };

  systemd.tmpfiles.rules = [
    "d /persist/codespace 0755 dev users -"
    # Optional: a git identity for containers to push with, when no ssh agent
    # is being forwarded. Holds only that key — never the host keys in
    # /persist/ssh, which are root-owned and useless for git anyway.
    "d /persist/git       0700 dev users -"
  ];
}
