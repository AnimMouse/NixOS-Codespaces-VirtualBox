{ config, lib, pkgs, ... }:

let
  p = import ../paths.nix;

  # Mounted into every codespace at /mnt/github. One directory for all of them,
  # not one each: the services tell codespaces apart by asking the kernel which
  # container the connecting process is in (SO_PEERCRED and its cgroup), which
  # nothing inside a container can forge — so no per-codespace units, which
  # nginx only just removed for the editors. The launcher mounts the directory,
  # not the socket, so a restarted socket unit cannot strand a container on a
  # dead inode.
  dir = "/run/codespace-auth";

  git-sign-service = pkgs.writers.writePython3Bin "git-sign-service"
    { flakeIgnore = [ "E501" ]; }
    (builtins.replaceStrings [ "@KEY_FILE@" ] [ p.keyFile ]
      (builtins.readFile ../scripts/git-sign-service));

  # Runs inside the container's own image, so a plain #!/bin/sh file rather
  # than writeShellApplication. Still shellchecked, as POSIX sh.
  git-sign-codespace = pkgs.writeTextFile {
    name = "git-sign-codespace";
    executable = true;
    text = builtins.readFile ../scripts/git-sign-codespace;
    checkPhase = "${lib.getExe pkgs.shellcheck} -s sh $target";
  };
in
{
  # Credentials for codespaces that never hand them the key. docs/GITHUB-APP.md
  # has the plan; this is its phase 1, commit signing. An ssh-agent cannot tell
  # signing from authenticating, so a container holding the forwarded agent can
  # push to any repository. Signing here, on the VM, with the one key — and
  # returning only the signature, in namespace "git", which cannot be used to
  # log in — lets the agent stop being forwarded once the token broker
  # (phase 2) covers authentication.
  #
  # Which codespaces use it is the launcher's GIT_SIGNING setting.
  systemd.sockets.codespace-sign = {
    description = "Commit signing for codespaces";
    wantedBy = [ "sockets.target" ];
    listenStreams = [ "${dir}/sign.sock" ];
    socketConfig = {
      # One short-lived handler per signature, as vm-control does.
      Accept = true;
      MaxConnections = 8;
      # uid 1000 is dev here and the remote user of every devcontainers base
      # image, so containers can connect and nothing else on the VM can.
      SocketUser = "dev";
      SocketGroup = "users";
      SocketMode = "0600";
      DirectoryMode = "0755";
    };
  };

  systemd.services."codespace-sign@" = {
    description = "Commit signing request";
    # ssh-keygen and ssh-add, which do the actual work.
    path = [ pkgs.openssh ];
    environment = {
      # dev's agent, at the stable path the launcher already forwards from.
      SSH_AUTH_SOCK = "/run/user/1000/ssh-agent";
    };
    serviceConfig = {
      ExecStart = lib.getExe git-sign-service;
      StandardInput = "socket";
      StandardOutput = "socket";
      StandardError = "journal";

      # dev, for the agent and the key file. Narrowed to what signing needs:
      # it reads /persist/git and talks to the agent, and touches nothing else.
      User = "dev";
      Group = "users";
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      PrivateTmp = true;
      PrivateNetwork = true;
      InaccessiblePaths = map (x: "-${x}") [
        "/persist/ssh"
        "/persist/secrets"
        "/persist/tls"
        "/persist/github-app"
        "/persist/code-server"
        "/persist/home"
        "/persist/codespace"
        "/persist/repos"
        "/persist/docker"
      ];
      RuntimeMaxSec = "1min";
    };
  };

  # Root-owned, so a container that has it mounted can use the socket but not
  # replace the client every other container runs.
  systemd.tmpfiles.rules = [
    "d  ${dir}                    0755 root root -"
    "C+ ${dir}/git-sign-codespace -    -    -    - ${git-sign-codespace}"
  ];
}
