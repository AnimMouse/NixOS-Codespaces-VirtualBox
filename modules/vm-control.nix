{ config, lib, pkgs, ... }:

let
  p = import ../paths.nix;

  # Where the socket lives. The launcher mounts this whole directory, not the
  # socket file: a file bind mount pins the inode, so a socket recreated by a
  # restart of this unit would leave every container holding a dead one.
  dir = "/run/vm-control";

  vm-control = pkgs.writeShellApplication {
    name = "vm-control";
    runtimeInputs = with pkgs; [
      coreutils gawk git docker systemd config.nix.package
    ];
    text = builtins.replaceStrings
      [ "@FLAKE_DIR@" "@FLAKE_ATTR@" ]
      [ p.flakeDir p.flakeAttr ]
      (builtins.readFile ../scripts/vm-control);
  };

  # The container-side client. A plain file rather than writeShellApplication:
  # it runs inside the codespace's own image, where a /nix/store shebang means
  # nothing, so it must stay `#!/bin/sh`. Still shellchecked, as POSIX sh.
  vm-client = pkgs.writeTextFile {
    name = "vm";
    executable = true;
    text = builtins.readFile ../scripts/vm;
    checkPhase = "${lib.getExe pkgs.shellcheck} -s sh $target";
  };
in
{
  # A codespace can edit this flake, but cannot see the machine it describes:
  # no systemd, no VM store, no journal. This socket lets the codespaces that
  # edit the flake ask — read-only questions, and builds with the VM's own
  # store, which also spares the container's store its cold start.
  #
  # Deliberately not ssh from the container: that needs a key inside it and a
  # change to sshd, which is the lockout-prone corner of this machine. And
  # deliberately nothing that applies: the asking container can write the
  # checkout, so a socket that could switch would make it root on the VM.
  # Which codespaces get the socket is the launcher's call — VM_CONTROL.
  systemd.sockets.vm-control = {
    description = "VM control socket for codespaces";
    wantedBy = [ "sockets.target" ];
    listenStreams = [ "${dir}/control.sock" ];
    socketConfig = {
      # One short-lived instance per request, so a wedged one cannot block the
      # next, and a client that hangs up takes its instance with it.
      Accept = true;
      MaxConnections = 4;
      # dev is uid 1000, and so is the remote user of every devcontainers base
      # image, so the container can connect and nothing else here can.
      SocketUser = "dev";
      SocketGroup = "users";
      SocketMode = "0600";
      DirectoryMode = "0755";
    };
  };

  systemd.services."vm-control@" = {
    description = "VM control request";
    serviceConfig = {
      ExecStart = lib.getExe vm-control;
      StandardInput = "socket";
      StandardOutput = "socket";
      StandardError = "journal";

      # dev, for the docker group and the journal (via wheel). Everything below
      # narrows what dev can do from here: a request is answered by a fixed
      # verb, but the flake it builds is whatever the codespace wrote.
      User = "dev";
      Group = "users";
      # No sudo, whatever a verb ends up running.
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      PrivateTmp = true;
      # A home of its own, so nix and git read none of dev's config and the
      # real home can be hidden outright. Also the eval cache's only
      # writable place.
      CacheDirectory = "vm-control";
      Environment = [ "HOME=/var/cache/vm-control" ];
      # Credentials dev can read and no verb needs. The flake is evaluated in
      # pure mode and built in the sandbox, which already keep it from these;
      # this keeps them out of reach of the dispatcher too. `-` tolerates a
      # path that does not exist yet.
      InaccessiblePaths = map (x: "-${x}") [
        "/persist/git"
        "/persist/ssh"
        "/persist/secrets"
        "/persist/code-server"
        "/persist/tls"
        "/persist/home"
        "/persist/codespace/secrets"
        "/run/user"
      ];
      # Long enough for a cold build of this flake, short enough that a stuck
      # one goes away by itself.
      RuntimeMaxSec = "1h";
    };
  };

  # Root-owned, so a container that has it mounted can use the socket but not
  # replace the client other containers run.
  systemd.tmpfiles.rules = [
    "d  ${dir}    0755 root root -"
    "C+ ${dir}/vm -    -    -    - ${vm-client}"
  ];
}
