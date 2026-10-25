{ config, lib, pkgs, ... }:

let
  stateDir = "/persist/code-server";
in
{
  # The hub editor: runs on the VM itself, for managing repos and editing this
  # flake. Per-project editors live inside their dev containers.
  services.code-server = {
    enable = true;
    user = "dev";
    group = "users";

    # A unix socket, not a port: nginx (modules/editor-proxy.nix) is the only
    # way in, and it has already checked the client certificate, so the editor
    # itself asks for nothing. It used to listen on 0.0.0.0:8000 with a
    # password — reachable from every container, which all held that password.
    # host/port are still passed by the module and ignored by code-server.
    #
    # In the setgid-nginx directory, so the socket gets nginx's group and 0660
    # is enough for nginx to connect.
    socket = "/run/editors/8000/editor.sock";
    socketMode = "0660";
    auth = "none";

    # On /persist so installed extensions and editor state survive a wipe of
    # system.vdi. Open VSX is the only marketplace code-server can reach —
    # there is no Pylance and no official C/C++ extension.
    userDataDir = "${stateDir}/user-data";
    extensionsDir = "${stateDir}/extensions";

    disableTelemetry = true;
    disableUpdateCheck = true;

    extraPackages = with pkgs; [ git ];
  };

  # The socket directory, made here as well as by tmpfiles: on a switch the
  # tmpfiles rules are re-applied by sysinit-reactivation.target, with nothing
  # ordering that before this unit's restart. `+` runs it as root, which the
  # nginx group needs; idempotent, and it repairs a mode if anything drifted.
  systemd.services.code-server.serviceConfig.ExecStartPre = [
    "+${pkgs.coreutils}/bin/install -d -o dev -g nginx -m 2750 /run/editors /run/editors/8000"
  ];
}
