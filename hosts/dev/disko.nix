# system.vdi — the disposable disk. Nix store and OS only.
#
# GPT + BIOS boot (EF02) rather than UEFI on purpose. UEFI gives this VM
# nothing it needs, and its failures are worse headless: VirtualBox's EFI NVRAM
# forgets boot entries (avoidable by installing to the removable fallback path)
# and drops you at the EFI shell. BIOS/GRUB is the path proven through a full
# wipe and reinstall, needs no extra checkbox in the GUI, and no recovery
# ritual. CLAUDE.md §9 has the full reasoning.
#
# Addressed by SATA port, not by /dev/sdX and not by /dev/disk/by-id/.
#
#   sdX      the kernel hands out letters in probe-completion order, which is
#            NOT port order and differs between the ISO and the installed
#            system. Observed in practice: port 1 came up as sda. Hardcoding
#            sda here pointed both the formatter and grub-install at the wrong
#            disk, and would have erased /persist on the first reinstall.
#   by-id    encodes the .vdi's random serial, so it changes every time
#            system.vdi is recreated — which this design does on purpose.
#   by-path  identifies the slot. The disposable disk's identity should come
#            from where it is plugged in, not from which file is plugged in.
#
# ata-1 is SATA port 0. The PCI address is VirtualBox's default PIIX3 SATA
# controller; switching the VM to ICH9 would change it.
{
  disko.devices.disk.system = {
    type = "disk";
    device = "/dev/disk/by-path/pci-0000:00:1f.2-ata-1";
    content = {
      type = "gpt";
      partitions = {
        # 1 MiB with no filesystem: GRUB's core image lives here on GPT+BIOS.
        bios = {
          priority = 1;
          size = "1M";
          type = "EF02";
        };

        root = {
          priority = 2;
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
            mountOptions = [ "noatime" ];
            extraArgs = [ "-L" "nixos" ];
          };
        };
      };
    };
  };
}
