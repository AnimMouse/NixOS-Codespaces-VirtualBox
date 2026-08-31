# system.vdi — the disposable disk. Nix store and OS only.
#
# GPT + BIOS boot (EF02) rather than UEFI on purpose: VirtualBox's EFI NVRAM
# routinely forgets boot entries and drops you at the EFI shell, and §7 has the
# user creating the VM by hand in the GUI. BIOS/GRUB needs no extra checkbox and
# no recovery ritual.
#
# /dev/sda == the disk on SATA port 0. VirtualBox generates a random serial per
# .vdi, so /dev/disk/by-id/ paths cannot be committed to a repo.
{
  disko.devices.disk.system = {
    type = "disk";
    device = "/dev/sda";
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
