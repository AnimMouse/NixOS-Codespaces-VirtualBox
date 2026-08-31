# persist.vdi — the disk that must never be lost.
#
# Deliberately in its own file so it can be left out of the reinstall
# partitioning run. See diskoConfigurations in flake.nix.
#
# /dev/sdb == the disk on SATA port 1.
{
  disko.devices.disk.persist = {
    type = "disk";
    device = "/dev/sdb";
    content = {
      type = "gpt";
      partitions.persist = {
        size = "100%";
        content = {
          type = "filesystem";
          format = "ext4";
          mountpoint = "/persist";
          mountOptions = [ "noatime" ];
          # Labelled so it can be mounted by hand from the ISO during a
          # reinstall, when disko is only being pointed at the system disk.
          extraArgs = [ "-L" "persist" ];
        };
      };
    };
  };
}
