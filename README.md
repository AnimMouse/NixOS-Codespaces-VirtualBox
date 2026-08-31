# NixOS-Codespaces-VirtualBox

A self-hosted, browser-based development environment modelled on GitHub
Codespaces: a headless NixOS VM under VirtualBox on a Windows host, serving
per-project dev containers whose `code-server` editors you open in Firefox at
`http://localhost:<port>`.

The VM is declared entirely in this repo. The dev containers are disposable and
follow the standard Dev Container spec, so `devcontainer.json` files stay
portable to real Codespaces.

**Success criterion:** the VM can be deleted and rebuilt from the official NixOS
ISO plus this repo, with no manual configuration beyond the bootstrap sequence,
and no loss of work.

---

## Status

| Phase | Scope | State |
|---|---|---|
| **1** | Bootable machine — flake, disko, users, SSH, `/persist` | **Built. Not yet installed on real hardware.** |
| 2 | Docker, `@devcontainers/cli`, the `codespace` launcher | Not started |
| 3 | home-manager, dotfiles repo, kiosk shortcuts | Not started |
| 4 | CI-built OVA (`nix build .#vbox`) | Stubbed on purpose |

Phase 1 has been evaluated and built against the pinned nixpkgs in `flake.lock`
(26.05.20260829, Linux 6.18.48); both disko entry points have been dry-run and
the lockout assertion tested. What no amount of evaluation can prove is that
GRUB boots, that VirtualBox presents the disks as `sda`/`sdb`, and that sshd
answers on the forwarded port. **That is what the next install is for.**

There is no Docker, no devcontainer CLI and no code-server in here yet.

---

## Quick start

Full walkthrough with every VirtualBox setting: **[docs/BOOTSTRAP.md](docs/BOOTSTRAP.md)**.
The short version:

1. **VirtualBox GUI** — new VM, two disks (`system.vdi` 40 GB on SATA port 0,
   `persist.vdi` 80 GB on SATA port 1), BIOS firmware (*not* EFI), NAT adapter
   with the port forwards below, NixOS 26.05 minimal ISO attached.
2. **Boot the ISO in a GUI window** (headless gives you no console), then
   `passwd` and `sudo systemctl start sshd`.
3. **From Windows Terminal**, `ssh -p 2222 nixos@localhost`, then partition and
   install:

   ```bash
   sudo nix --experimental-features "nix-command flakes" run \
     github:nix-community/disko -- --mode destroy,format,mount \
     --flake github:AnimMouse/NixOS-Codespaces-VirtualBox#first-install

   sudo nixos-install --flake github:AnimMouse/NixOS-Codespaces-VirtualBox#dev
   ```

   Expect 20–40 minutes, almost entirely downloads. It prompts for a root
   password at the end — don't skip it.
4. **Eject the ISO**, reboot, then `ssh-keygen -R "[localhost]:2222"` on the
   host and `ssh -p 2222 dev@localhost`.

Initial login is `dev` / `dev`. Change it with `passwd`.

---

## Two disko entry points — read this before reinstalling

`disko --mode destroy,format,mount` is unconditionally destructive, so the disks
are exposed as two separate targets:

| Target | Formats | Use when |
|---|---|---|
| `#first-install` | `system.vdi` **and** `persist.vdi` | The very first install, or when you genuinely want to throw away everything |
| `#dev` | `system.vdi` only | Every reinstall. `/persist` survives |

`#first-install` mounts `/mnt/persist` for you; `#dev` does not, so the
reinstall path needs `mount /dev/disk/by-label/persist /mnt/persist` before
`nixos-install`. Skipping that puts `/persist/home/dev` on the *system* disk,
where it is silently shadowed the moment the real disk mounts at boot.

This is the one place the repo departs from `CLAUDE.md` §7, which uses `#dev`
for the initial install. A single target covering both disks would erase
`/persist` on every rebuild, contradicting the storage contract in §3.

---

## Daily use

```powershell
# from Windows, after any change to this repo
ssh -p 2222 dev@localhost 'sudo nixos-rebuild switch --flake /persist/dev-vm#dev'
```

or `rebuild` from a shell inside the VM (a shell alias for the same thing).
Passwordless sudo is enabled for `wheel` precisely so the non-interactive form
works — `ssh host 'sudo ...'` gets no TTY and cannot answer a password prompt.

The working copy lives at `/persist/dev-vm`, on the disk that survives a wipe,
so the machine can always rebuild itself.

---

## What lives where

Everything precious is in exactly two places: `/persist`, and GitHub.

| Disk | Mount | Contents | On rebuild |
|---|---|---|---|
| `system.vdi` (40 GB) | `/` | Nix store, OS | Delete freely |
| `persist.vdi` (80 GB) | `/persist` | repos, SSH keys, secrets, home | **Keep** |

Inside `/persist`:

```
/persist/ssh/            SSH host keys + authorized_keys.<user>
/persist/home/dev/       the dev user's real home (/home/dev symlinks here)
/persist/repos/          project checkouts
/persist/secrets/        secrets, mode 0700
/persist/dev-vm/         this repo, for the rebuild loop
```

`/persist` is `neededForBoot`, so it mounts in the initrd before activation. A
detached `persist.vdi` is a hard boot failure by design — the alternative is new
state landing quietly on the disposable disk.

---

## Networking

NAT with every forward bound to `127.0.0.1`. Set the host IP explicitly; a blank
field binds `0.0.0.0` and exposes the VM to your LAN.

| Host | Guest | Purpose |
|---|---|---|
| `127.0.0.1:2222` | 22 | SSH / rebuilds |
| `127.0.0.1:8000` | 8000 | Hub code-server (Phase 2) |
| `127.0.0.1:8001-8010` | 8001-8010 | Per-container editors (Phase 2) |

No host-only adapter, deliberately. `http://localhost` is a browser secure
context; `http://192.168.56.x` is not, which breaks the Clipboard API, service
workers and several code-server features.

---

## Repo layout

```
flake.nix                       nixpkgs 26.05 + disko; both disko entry points
flake.lock                      pinned — do not float to unstable
hosts/dev/
  configuration.nix             boot, network, sshd, users, nix settings
  disko.nix                     system.vdi  (/dev/sda) — disposable
  disko-persist.nix             persist.vdi (/dev/sdb) — separate file so it
                                can be left out of a reinstall
modules/
  persist.nix                   /persist wiring: host keys, home, tmpfiles
docs/BOOTSTRAP.md               the full install walkthrough
.github/workflows/build-ova.yml Phase 4 stub — dispatch-only, no-op
CLAUDE.md                       design decisions and constraints
```

---

## Why it's built this way

The host runs Windows with Hyper-V, VBS, WSL2 and Windows Sandbox all
deliberately off, so VirtualBox gets real VT-x and gaming performance is
unaffected. **There is no Nix on the host**, and that single fact drives most of
the design:

- **Official ISO + disko + `nixos-install --flake`**, not a custom ISO or OVA —
  both would need a Linux+Nix builder the host cannot provide. The official ISO
  never goes stale.
- **Rebuilds are driven from inside the VM**, never `--target-host`, for the
  same reason.
- **`@devcontainers/cli` + Docker**, not Coder. Coder's own recommended path is
  the same CLI; its added value is multi-user (RBAC, quotas, audit) and worthless
  for one developer, while costing a `coderd` + Postgres footprint in a VM being
  kept lean. Containers need no nested virtualisation — Docker on Linux is just
  namespaces and cgroups.
- **`code-server` inside each container**, so language servers run on normal FHS
  userland and `nix-ld` is unnecessary. No Electron editor is involved anywhere.
- **BIOS/GRUB, not UEFI.** VirtualBox's EFI implementation loses its boot entry
  often enough to be a recurring nuisance, and a headless VM gives you no
  graceful exit from the EFI shell.
- **Distinct ports, not subdomain routing** — `*.localhost` resolution is
  inconsistent across platforms and not worth debugging.

The VM itself stays thin: no X11, no desktop, no toolchains. Toolchains belong
in containers, which is also why NixOS's FHS incompatibility is a non-issue
here.

---

## Gotchas worth knowing

- **Turtle icon in the VirtualBox status bar** means Hyper-V has leaked back and
  VirtualBox has fallen back to the Windows Hypervisor Platform API.
  Performance drops 2–5×. Fix on the host with
  `bcdedit /set hypervisorlaunchtype off`, then reboot Windows.
- **Host key collision.** The ISO and the installed system both answer on
  `localhost:2222` with different keys. Host keys are persisted to
  `/persist/ssh/`, so `ssh-keygen -R "[localhost]:2222"` is needed exactly once,
  ever — not on every reinstall.
- **Lockout.** A user with no password and no authorized key produces an
  unloggable machine, since sshd rejects empty passwords. The config carries an
  assertion that refuses to build in that state.
- **Firefox keybinds** (Phase 2). `Ctrl+Shift+P` opens a Private Window, not the
  command palette — use `F1`. `Ctrl+W` closes the tab and the editor with it.
- **Marketplace** (Phase 2). `code-server` uses Open VSX, not Microsoft's, so
  there is no Pylance and no official C/C++ extension.

---

## Contributing to this config

Read `CLAUDE.md` first — it records which decisions are settled and why.
In short: prefer NixOS modules over activation scripts or hand-written units,
keep `flake.lock` pinned, verify option names against the installed nixpkgs
rather than from memory, and give every module a comment explaining *why*.

To check a change without a VM:

```bash
nix flake check
nix build .#nixosConfigurations.dev.config.system.build.toplevel --no-link
nix run github:nix-community/disko -- --mode destroy,format,mount \
  --flake .#dev --dry-run
```
