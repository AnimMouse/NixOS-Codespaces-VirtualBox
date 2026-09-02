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

    # Must be 0.0.0.0, not 127.0.0.1: VirtualBox's NAT forward delivers to the
    # guest's own address, so a loopback bind inside the VM is unreachable. The
    # forward itself is bound to 127.0.0.1 on the Windows side, which is what
    # keeps this off the LAN.
    host = "0.0.0.0";
    port = 8000;

    auth = "password";

    # On /persist so installed extensions and editor state survive a wipe of
    # system.vdi. Open VSX is the only marketplace code-server can reach —
    # there is no Pylance and no official C/C++ extension.
    userDataDir = "${stateDir}/user-data";
    extensionsDir = "${stateDir}/extensions";

    disableTelemetry = true;
    disableUpdateCheck = true;

    extraPackages = with pkgs; [ git ];
  };

  # §8: no password hash may be committed to a public repo, so one is generated
  # on first boot and logged to the journal exactly once. The module already
  # sets HASHED_PASSWORD (empty by default, which code-server treats as unset),
  # so PASSWORD from this file is what takes effect.
  systemd.services.code-server-password = {
    description = "Generate the code-server password on first boot";
    wantedBy = [ "multi-user.target" ];
    before = [ "code-server.service" ];
    unitConfig.RequiresMountsFor = stateDir;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      UMask = "0077";
    };
    path = with pkgs; [ coreutils ];
    script = ''
      mkdir -p ${stateDir}
      chmod 0751 ${stateDir}

      if [ ! -s ${stateDir}/pw ]; then
        tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 24 > ${stateDir}/pw
        echo
        echo "code-server password generated: $(cat ${stateDir}/pw)"
        echo "It is stored in ${stateDir}/pw and will not be printed again."
      fi

      # Readable by dev: both code-server itself and the codespace launcher
      # need it, and the launcher runs unprivileged.
      chown dev:users ${stateDir}/pw
      chmod 0640 ${stateDir}/pw

      printf 'PASSWORD=%s\n' "$(cat ${stateDir}/pw)" > ${stateDir}/env
      chown dev:users ${stateDir}/env
      chmod 0640 ${stateDir}/env
    '';
  };

  systemd.services.code-server = {
    after = [ "code-server-password.service" ];
    requires = [ "code-server-password.service" ];
    serviceConfig.EnvironmentFile = "${stateDir}/env";
  };
}
