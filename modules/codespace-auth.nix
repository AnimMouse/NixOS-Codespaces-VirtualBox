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
  dir = p.authDir;

  # The token broker's own state: cached tokens and the entitlements the
  # launcher writes per container. In /run, so cached tokens die with a reboot
  # and nothing scoped outlives the machine being up; the launcher rewrites an
  # entitlement on every `up`, which is what starts a container anyway.
  # dev-only, and never mounted into a container.
  stateDir = "/run/codespace-auth-state";

  github-token-service = pkgs.writers.writePython3Bin "github-token-service"
    { flakeIgnore = [ "E501" ]; }
    (builtins.replaceStrings [ "@GITHUB_APP_DIR@" "@STATE_DIR@" ] [ p.githubAppDir stateDir ]
      (builtins.readFile ../scripts/github-token-service));

  git-sign-service = pkgs.writers.writePython3Bin "git-sign-service"
    { flakeIgnore = [ "E501" ]; }
    (builtins.replaceStrings [ "@KEY_FILE@" ] [ p.keyFile ]
      (builtins.readFile ../scripts/git-sign-service));

  # The container-side clients, all plain #!/bin/sh: they run inside each
  # codespace's own image, where a /nix/store shebang means nothing. Still
  # shellchecked, as POSIX sh. Copied into ${dir} below, so a VM rebuild
  # updates them in every container at once (codespace-auth-clients).
  shClient = name: pkgs.writeTextFile {
    inherit name;
    executable = true;
    text = builtins.readFile (../scripts + "/${name}");
    checkPhase = "${lib.getExe pkgs.shellcheck} -s sh $target";
  };
  git-sign-codespace = shClient "git-sign-codespace";
  # Phase 3, GITHUB_AUTH=app: git's credential helper, and the gh shim.
  git-credential-codespace = shClient "git-credential-codespace";
  gh-codespace = shClient "gh-codespace";
  clients = [ git-sign-codespace git-credential-codespace gh-codespace ];
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

  # Phase 2: the token broker (docs/GITHUB-APP.md §4.3). Same shape as
  # signing — one socket for every codespace, one short handler per request,
  # the caller identified by the kernel — and the refresh serialised by a lock
  # instead of by being one long-running process. Refresh tokens rotate on
  # use, so two refreshes at once would lock the VM out.
  systemd.sockets.codespace-token = {
    description = "Scoped GitHub tokens for codespaces";
    wantedBy = [ "sockets.target" ];
    listenStreams = [ "${dir}/token.sock" ];
    socketConfig = {
      Accept = true;
      MaxConnections = 16;
      SocketUser = "dev";
      SocketGroup = "users";
      SocketMode = "0600";
      DirectoryMode = "0755";
    };
  };

  systemd.services."codespace-token@" = {
    description = "Scoped GitHub token request";
    serviceConfig = {
      ExecStart = lib.getExe github-token-service;
      StandardInput = "socket";
      StandardOutput = "socket";
      StandardError = "journal";

      # dev, which owns the app's credentials. Writes only where it must: the
      # rotated refresh token, and its cache.
      User = "dev";
      Group = "users";
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      ReadWritePaths = [ p.githubAppDir stateDir ];
      InaccessiblePaths = map (x: "-${x}") [
        "/persist/ssh"
        "/persist/secrets"
        "/persist/tls"
        "/persist/git"
        "/persist/code-server"
        "/persist/home"
        "/persist/codespace"
        "/persist/repos"
        "/persist/refs"
        "/persist/docker"
        "/run/user"
      ];
      RuntimeMaxSec = "1min";
    };
  };

  # The container-side clients, copied into ${dir} so every container sees the
  # current ones. Not tmpfiles `C+`, which this used to be: a switch does not
  # re-run it, so a rebuild left every container on the old clients until the
  # next boot — observed after phase 4, with the new broker answering the old
  # helper. A oneshot whose ExecStart names the store paths changes whenever a
  # client does, so the switch restarts it. Each file is replaced by rename,
  # never rewritten in place, so a container mid-push never runs half a file.
  # Root-owned, so a container that has the directory mounted can use the
  # sockets but not replace the client every other container runs.
  systemd.services.codespace-auth-clients = {
    description = "Install the codespace credential clients";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-tmpfiles-setup.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = map (c: "${pkgs.coreutils}/bin/install -D -m 0555 -o root -g root ${c} ${dir}/.${c.name}.new") clients
        ++ map (c: "${pkgs.coreutils}/bin/mv -f ${dir}/.${c.name}.new ${dir}/${c.name}") clients;
    };
  };

  systemd.tmpfiles.rules = [
    "d  ${dir}                    0755 root root -"
    "d  ${stateDir}               0700 dev  users -"
    "d  ${stateDir}/entitlements  0700 dev  users -"
  ];
}
