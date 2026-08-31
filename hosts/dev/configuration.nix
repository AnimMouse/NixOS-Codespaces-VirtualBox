{ config, lib, pkgs, ... }:

{
  # ---------------------------------------------------------------- boot ----
  # See disko.nix for why BIOS rather than UEFI.
  #
  # `boot.loader.grub.devices` is deliberately NOT set here: disko's gpt type
  # already emits `devices = [ config.device ]` for any disk carrying an EF02
  # partition (lib/types/gpt.nix). Setting it again appends rather than
  # overrides, and grub then fails the build with "duplicated devices in
  # mirroredBoots".
  boot.loader.grub = {
    enable = true;
    efiSupport = false;
  };

  # VirtualBox's default storage controller is emulated SATA (ahci); ata_piix
  # covers the IDE fallback if the VM was created with the other controller.
  boot.initrd.availableKernelModules = [
    "ahci"
    "ata_piix"
    "ohci_pci"
    "ehci_pci"
    "sd_mod"
    "sr_mod"
  ];

  # VBoxService: mainly for time sync, which matters because a suspended VM
  # wakes with a clock far enough out to break TLS against github.com.
  # Seamless/clipboard/drag-and-drop are left off — they need X11, and §4 says
  # no X11 in this VM.
  virtualisation.virtualbox.guest.enable = true;

  nixpkgs.hostPlatform = "x86_64-linux";

  # ------------------------------------------------------------ networking --
  networking = {
    hostName = "dev";
    # Single NAT adapter handed out by VirtualBox's DHCP server.
    useDHCP = lib.mkDefault true;

    firewall = {
      enable = true;
      allowedTCPPorts = [ 22 ];
      # Phase 2: hub code-server on 8000, per-container editors on 8001-8010.
      # Opened now so the §3 NAT forwards work the moment those services exist,
      # rather than failing as a silent connection refused after a rebuild.
      allowedTCPPortRanges = [
        { from = 8000; to = 8010; }
      ];
    };
  };

  # ------------------------------------------------------------------ ssh --
  # The only way in. Host keys are pinned to /persist by modules/persist.nix.
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "no";
      # §7 bootstraps with a password before any key exists. The daemon is only
      # reachable through a 127.0.0.1-bound NAT forward, never from the LAN.
      PasswordAuthentication = true;
      KbdInteractiveAuthentication = false;
      PermitEmptyPasswords = false;
    };
  };

  # ----------------------------------------------------------------- users --
  users.mutableUsers = true;

  users.users.dev = {
    isNormalUser = true;
    description = "dev";
    extraGroups = [ "wheel" ];
    # Not a secret, and not committable as a hash either (§8: public repo).
    # `initialPassword` only applies when the account is first created, so a
    # `passwd` afterwards sticks — until system.vdi is wiped, at which point
    # this predictable default is exactly what you want to get back in.
    initialPassword = "dev";
  };

  # §3's rebuild loop is `ssh dev@localhost 'sudo nixos-rebuild ...'`, which
  # gets no TTY and therefore cannot answer a sudo password prompt.
  security.sudo.wheelNeedsPassword = false;

  # §8 lockout gotcha, encoded as a fix rather than a paragraph: refuse to build
  # a machine that nobody can log in to.
  assertions = [
    {
      assertion =
        let u = config.users.users.dev; in
        u.hashedPassword != null
        || u.hashedPasswordFile != null
        || u.initialPassword != null
        || u.initialHashedPassword != null
        || u.openssh.authorizedKeys.keys != [ ]
        || u.openssh.authorizedKeys.keyFiles != [ ];
      message = ''
        User 'dev' has no password and no authorized key, and sshd rejects
        empty passwords. This configuration would produce an unloggable
        machine after the next reboot.
      '';
    }
  ];

  # ------------------------------------------------------------------ nix --
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    trusted-users = [ "root" "dev" ];
  };

  # A 40 GB system disk fills up fast when every rebuild keeps its closure.
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };
  nix.optimise.automatic = true;

  # ------------------------------------------------------------- userland --
  # Deliberately thin: toolchains belong in dev containers (§3), not here.
  environment.systemPackages = with pkgs; [
    git
    vim
    curl
    rsync
    tmux
    htop
    jq
    file
    tree
  ];

  environment.variables.EDITOR = "vim";

  # No desktop, no printing, no sound, no docs (§4).
  documentation.nixos.enable = false;
  services.xserver.enable = false;

  time.timeZone = "UTC";

  system.stateVersion = "26.05";
}
