# Bootstrap — Phase 1

Building the VM from the official NixOS 26.05 minimal ISO. At the end of this
you have a headless machine you can SSH into on `127.0.0.1:2222`, with a
`/persist` disk that survives having the system disk deleted.

Installed and booted successfully on VirtualBox: sshd, `/persist`, persistent
host keys and the `nixos-rebuild` loop are all confirmed working on real
hardware. Disks are addressed by SATA slot rather than by `/dev/sdX`, after the
letters were observed swapping between the ISO and the installed system.

Nothing in Phase 1 installs Docker, the devcontainer CLI, or code-server. That
is Phase 2.

The flake is fetched straight from GitHub, so the repo must be pushed and public
before step 4. If you forked it, substitute your own owner/repo in the
`github:` URLs below.

---

## 1. Create the VM (VirtualBox GUI, by hand)

| Setting | Value |
|---|---|
| Type / Version | Linux / Other Linux (64-bit) |
| Memory | 8192 MB or more |
| CPUs | 4 or more |
| Firmware | **BIOS** — leave "Enable EFI" *unchecked* |
| Disk 1 | `system.vdi`, 40 GB, SATA port **0** |
| Disk 2 | `persist.vdi`, 80 GB, SATA port **1** |
| Network | Adapter 1 = NAT |
| Optical | attach `nixos-minimal-26.05-x86_64-linux.iso` |

The port order matters, and it is the *only* thing that identifies the disks.
The config addresses them by SATA slot:

| SATA port | `by-path` | Disk |
|---|---|---|
| 0 | `/dev/disk/by-path/pci-0000:00:1f.2-ata-1` | `system.vdi`, 40 GB |
| 1 | `/dev/disk/by-path/pci-0000:00:1f.2-ata-2` | `persist.vdi`, 80 GB |

Not `/dev/sda`/`/dev/sdb`: the kernel hands out letters in probe-completion
order, which is not port order and differs between the ISO and the installed
system. On this VM, port 1 came up as `sda`. Not `/dev/disk/by-id/` either,
because that encodes the `.vdi`'s random serial and would change every time
`system.vdi` is recreated — which is the whole point of the design.

The PCI address is VirtualBox's default PIIX3 SATA controller. If you switch the
VM to ICH9, it changes, and both disko files need updating.

EFI is off deliberately — VirtualBox's EFI implementation loses its boot entry
often enough to be a recurring nuisance, and there is no console-free way out of
the EFI shell on a headless VM.

**Port forwards** (Settings → Network → Adapter 1 → Advanced → Port Forwarding).
Set Host IP to `127.0.0.1` on every rule — not blank. A blank host IP binds
`0.0.0.0` and exposes the VM to the LAN.

| Name | Host IP | Host port | Guest port |
|---|---|---|---|
| ssh | 127.0.0.1 | 2222 | 22 |
| hub | 127.0.0.1 | 8000 | 8000 |
| ide01 … ide10 | 127.0.0.1 | 8001 … 8010 | 8001 … 8010 |

The 8000-8010 rules are unused until Phase 2. Adding them now saves reopening
this dialog later.

> **Turtle icon** in the status bar after boot means Hyper-V has leaked back and
> VirtualBox has fallen back to the Windows Hypervisor Platform API. Performance
> drops 2–5×. Fix it on the host before continuing:
> `bcdedit /set hypervisorlaunchtype off`, then reboot Windows.

---

## 2. Boot the ISO — with a GUI window

Not headless. You need a console to type at.

At the `nixos@nixos` prompt:

```bash
passwd                      # mandatory: sshd rejects empty passwords
sudo systemctl start sshd   # enabled on the ISO, but not started at boot
```

---

## 3. SSH in from Windows Terminal

```powershell
ssh -p 2222 nixos@localhost
```

Everything from here on is far easier over SSH than in the VirtualBox console
window, which has no scrollback and no clipboard.

---

## 4. Partition

**Confirm which disk is which, before anything destructive.** The `by-path`
links are what the config targets, so verify them rather than the letters:

```bash
lsblk -o NAME,SIZE,TYPE,LABEL,PARTLABEL
ls -l /dev/disk/by-path/
```

`...-ata-1` must resolve to the **40 GB** disk and `...-ata-2` to the **80 GB**
one. If they are the other way round, the `.vdi` files are on the wrong SATA
ports — fix that in the VirtualBox GUI rather than editing the config, or the
reinstall path will erase `/persist`.

**First install — this erases both disks:**

```bash
sudo nix --experimental-features "nix-command flakes" run \
  github:nix-community/disko -- --mode destroy,format,mount \
  --flake github:AnimMouse/NixOS-Codespaces-VirtualBox#first-install
```

**Reinstalling onto a fresh `system.vdi`, keeping `/persist`:**

```bash
sudo nix --experimental-features "nix-command flakes" run \
  github:nix-community/disko -- --mode destroy,format,mount \
  --flake github:AnimMouse/NixOS-Codespaces-VirtualBox#dev

sudo mkdir -p /mnt/persist
sudo mount /dev/disk/by-label/persist /mnt/persist
```

`#dev` covers the system disk only; `#first-install` covers both. This split is
the one deviation from §7 of `CLAUDE.md`, which uses `#dev` for the initial
install. `disko --mode destroy,format,mount` is unconditional, so a single
target that includes `persist.vdi` would destroy `/persist` on every reinstall —
which contradicts the storage table in §3. Making the destructive variant a
different word means you cannot wipe `/persist` by reflex.

`#first-install` mounts `/mnt/persist` for you. The reinstall path does not,
which is why it has the extra `mount` above — and getting that wrong is
expensive: `nixos-install` would then create `/persist/home/dev` on the *system*
disk, where it is silently shadowed the moment the real disk mounts at boot.

**Do not skip disko and go straight to `nixos-install`.** Without it, `/mnt` is
an ordinary directory on the ISO's overlay rather than a mounted filesystem.
`nixos-install` runs most of the way regardless and then dies at the very end
with `Failed to get blkid info (returned 512) for  on  ` — the blank fields are
the giveaway that the installer could not find a block device under `/mnt`.

So check before continuing, either way:

```bash
findmnt /mnt          # must be the 40 GB disk's root partition
findmnt /mnt/persist  # must be the 80 GB disk, LABEL=persist
lsblk -o NAME,SIZE,LABEL,PARTLABEL,MOUNTPOINT
```

Both must be real mounts. `/mnt` should show `disk-system-root` and
`/mnt/persist` should show `disk-persist-persist`.

---

## 5. Install

```bash
sudo nixos-install --flake github:AnimMouse/NixOS-Codespaces-VirtualBox#dev
```

20–40 minutes, almost all of it downloads.

It prompts for a **root password** at the end. Do not skip it — it is your way
back in if sshd does not come up.

The `dev` user's password is `dev` on a fresh install. Change it after first
boot with `passwd`; it will persist until the next time you wipe `system.vdi`.

---

## 6. Eject the ISO, then reboot

Devices → Optical Drives → Remove disk from virtual drive. Then:

```bash
sudo reboot
```

You can close the GUI window and start the VM headless from now on.

---

## 7. Get back in

The installed system has different host keys from the ISO, on the same
`localhost:2222`. On the Windows host, once:

```powershell
ssh-keygen -R "[localhost]:2222"
ssh -p 2222 dev@localhost
```

Those host keys now live in `/persist/ssh/`, so this is the last time you have
to do it — reinstalls will reuse the same fingerprint.

---

## 8. Set up the rebuild loop

Clone this repo to where the running system expects it:

```bash
sudo git clone https://github.com/AnimMouse/NixOS-Codespaces-VirtualBox /persist/dev-vm
sudo chown -R dev:users /persist/dev-vm
```

`flake.lock` is already committed, pinning nixpkgs to the `nixos-26.05` revision
this config was verified against. To move to a newer nixpkgs later:

```bash
cd /persist/dev-vm
nix flake update
sudo nixos-rebuild switch --flake /persist/dev-vm#dev
git commit -am "Update flake inputs" && git push
```

From the Windows host:

```powershell
ssh -p 2222 dev@localhost 'sudo nixos-rebuild switch --flake /persist/dev-vm#dev'
```

or `rebuild` from a shell inside the VM. Passwordless sudo is enabled for
`wheel` precisely so this non-interactive form works.

---

## 9. Verify Phase 1

```bash
# /persist is a separate disk, mounted early
findmnt /persist
lsblk -o NAME,SIZE,LABEL,MOUNTPOINT

# home really lives on it
readlink -f ~            # -> /persist/home/dev
ls -l /home/dev          # -> symlink into /persist

# host keys are persistent
ls -l /persist/ssh/

# the machine can rebuild itself
sudo nixos-rebuild switch --flake /persist/dev-vm#dev
```

**The actual Phase 1 acceptance test.** Write a marker, then destroy the system
disk and rebuild:

```bash
echo "survived $(date -Is)" | sudo tee -a /persist/marker
```

1. Power off. In the VirtualBox GUI, detach and delete `system.vdi`.
2. Create a new empty 40 GB `system.vdi` on SATA port 0.
3. Reattach the ISO, boot it, and repeat steps 2–7 using the **reinstall**
   command in step 4 (`#dev`, not `#first-install`). Run the `by-path` check
   first — a recreated `system.vdi` must go back on SATA port 0.
4. `cat /persist/marker` — both lines should be there, and the host should not
   have complained about a changed SSH fingerprint.

---

## Troubleshooting

**Boots to `GRUB rescue>` or "no bootable medium".**
The ISO is probably still attached, or `system.vdi` is not on SATA port 0.
From the ISO, confirm `/dev/disk/by-path/pci-0000:00:1f.2-ata-1` resolves to the
40 GB disk. GRUB is installed to that path, so if the disks are swapped the boot
sector lands on `persist.vdi`.

**`Failed to get blkid info (returned 512) for  on  ` at the end of
`nixos-install`.**
`/mnt` was not a mounted filesystem — the disko step in step 4 was skipped or
failed. The blank device and mount point in the message are the tell. Nothing
was written to disk; run disko, confirm with `findmnt /mnt`, and install again.

**`/persist` mounted, but from a partition that should not exist** (e.g.
`findmnt /persist` reports `/dev/sda1` when `sda1` is meant to be the 1 MiB BIOS
partition). Device letters are unstable; this is expected and harmless, since
every filesystem mounts by `by-partlabel`. It is only a problem if a *config*
still names a disk by letter — which is the bug this layout exists to avoid.

**Boot hangs waiting for `/persist`.**
`persist.vdi` is detached or on the wrong port. It is `neededForBoot`, so this
is a hard stop by design rather than a silent fallback to the disposable disk.

**Clock skew breaking TLS after resuming a suspended VM.**
`sudo systemctl restart systemd-timesyncd`.
