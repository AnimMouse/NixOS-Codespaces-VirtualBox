{
  description = "Headless NixOS dev VM for VirtualBox — Codespaces-style dev containers";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { self, nixpkgs, disko, ... }:
    let
      systemDisk = import ./hosts/dev/disko.nix;
      persistDisk = import ./hosts/dev/disko-persist.nix;
    in
    {
      nixosConfigurations.dev = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          disko.nixosModules.disko

          # Both disks are declared to the running system, so / and /persist
          # both get declarative fileSystems entries. Which disks are
          # *formatted* is decided by diskoConfigurations below, not by this
          # module list.
          ./hosts/dev/disko.nix
          ./hosts/dev/disko-persist.nix

          ./hosts/dev/configuration.nix
          ./modules/persist.nix
        ];
      };

      # Two partitioning entry points, because `disko --mode
      # destroy,format,mount` is unconditionally destructive and §3 requires
      # persist.vdi to survive a rebuild. Keeping them separate makes wiping
      # /persist an explicit act rather than a reflex.
      #
      #   first install .... #first-install   formats system.vdi AND persist.vdi
      #   reinstall ........ #dev             formats system.vdi only
      #
      # These must be plain attribute sets: the disko CLI reads
      # `cfg.disko.devices` straight off them (share/disko/default.nix), so a
      # bare path or a module using `imports` fails, even though both are
      # perfectly good NixOS modules in the list above.
      diskoConfigurations = {
        dev = systemDisk;

        first-install = {
          disko.devices.disk =
            systemDisk.disko.devices.disk // persistDisk.disko.devices.disk;
        };
      };
    };
}
