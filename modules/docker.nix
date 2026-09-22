{ config, lib, pkgs, ... }:

{
  virtualisation.docker = {
    enable = true;

    # Docker's own data-root rather than a bind mount of /var/lib/docker onto
    # /persist/docker (CLAUDE.md §8 suggests the bind mount). A bind mount needs
    # its source to exist before systemd mounts it, which is the same first-boot
    # ordering trap that /home/dev sidesteps by being a symlink. dockerd creates
    # data-root itself, long after /persist is up, so there is nothing to order.
    daemon.settings.data-root = "/persist/docker";

    autoPrune = {
      enable = true;
      dates = "weekly";
      # `docker system prune -f` on its own also deletes *stopped* containers,
      # and `codespace down` stops rather than removes them — so an untuned
      # prune silently discards a codespace that is merely idle.
      #
      # `until` does not prevent that: it matches on container *creation* time,
      # not last use, so one created a month ago and stopped last night is
      # still older than 168h and still goes. The label is the real guard —
      # every codespace container carries `codespace=<name>` from the
      # launcher's --id-label, and `codespace rm` is the only path that should
      # remove one. `until` stays, to bound dangling images and networks.
      flags = [ "--filter" "until=168h" "--filter" "label!=codespace" ];
    };
  };

  # Membership of `docker` is root-equivalent. That is acceptable here: the VM
  # has one user, who already has passwordless sudo.
  users.users.dev.extraGroups = [ "docker" ];

  environment.systemPackages = with pkgs; [
    devcontainer
    docker-compose # only needed by compose-based devcontainer.json files
  ];
}
