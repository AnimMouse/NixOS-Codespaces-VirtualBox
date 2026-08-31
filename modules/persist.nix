{ config, lib, pkgs, ... }:

{
  # The activation script and the sshd key generator both run before most units,
  # so /persist has to be up in stage 1 rather than mounted by systemd later.
  # This also makes a missing/detached persist.vdi a loud boot failure instead of
  # a quiet one where new state silently lands on the disposable disk.
  fileSystems."/persist".neededForBoot = true;

  # §8 known_hosts collision: the ISO and the installed system both answer on
  # localhost:2222 with different keys. Generating the installed system's keys
  # onto /persist means the host only has to accept a new fingerprint once, and
  # never again across reinstalls.
  services.openssh.hostKeys = [
    {
      path = "/persist/ssh/ssh_host_ed25519_key";
      type = "ed25519";
    }
    {
      path = "/persist/ssh/ssh_host_rsa_key";
      type = "rsa";
      bits = 4096;
    }
  ];

  # Public keys dropped here survive a wipe too. Named per-user via %u, appended
  # to the defaults so ~/.ssh/authorized_keys keeps working. sshd tolerates the
  # file being absent, which is the state on a fresh install.
  services.openssh.authorizedKeysFiles = [ "/persist/ssh/authorized_keys.%u" ];

  # The home directory *is* the persistent one, rather than /home/dev
  # bind-mounted over it. A bind mount would have to be neededForBoot as well,
  # and would then fail the boot on a first install where the source directory
  # does not exist yet.
  users.users.dev.home = "/persist/home/dev";

  systemd.tmpfiles.rules = [
    # 0700: authorized keys and, later, git credentials live under here.
    "d /persist/ssh          0700 root root -"
    "d /persist/home         0755 root root -"
    "d /persist/home/dev     0700 dev  users -"
    # Repos checked out by hand or, from Phase 2, by the codespace launcher.
    "d /persist/repos        0755 dev  users -"
    "d /persist/secrets      0700 root root -"

    # Muscle memory and any tooling that hardcodes /home/<user>.
    "d  /home                0755 root root -"
    "L+ /home/dev            -    -    -    - /persist/home/dev"
  ];

  # This flake's own working copy. §3's rebuild loop reads it from here, so a
  # `nixos-rebuild switch` keeps working after system.vdi has been thrown away.
  # Cloned by hand once — see docs/BOOTSTRAP.md.
  environment.shellAliases.rebuild =
    "sudo nixos-rebuild switch --flake /persist/dev-vm#dev";
}
