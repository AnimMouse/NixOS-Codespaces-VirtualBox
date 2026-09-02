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
| **1** | Bootable machine — flake, disko, users, SSH, `/persist` | **Done.** Survived a `system.vdi` wipe |
| **2** | Docker, `@devcontainers/cli`, the `codespace` launcher | **Built and tested.** Not yet run on the VM |
| 3 | home-manager, dotfiles repo, kiosk shortcuts | Not started |
| 4 | CI-built OVA (`nix build .#vbox`) | Stubbed on purpose |

Phase 1 is **proven on real hardware**: ISO install, reboot, SSH on the
forwarded port, persistent host keys, `nixos-rebuild` from `/persist/dev-vm`,
and a full `system.vdi` wipe-and-reinstall with `/persist` intact.

Disks are addressed by SATA slot (`/dev/disk/by-path/...`), not by `/dev/sdX`.
The letters were observed swapping between the ISO kernel and the installed one,
which pointed both the partitioner and `grub-install` at the wrong disk. See
[Two disko entry points](#two-disko-entry-points--read-this-before-reinstalling).

Phase 2 adds Docker, the devcontainer CLI, the hub editor and the `codespace`
launcher. The launcher was exercised end to end against a real Ubuntu dev
container — up, rebuild, down, list, logs, port allocation, editor reachable
through the proxy — but on a Linux host, not yet inside the VM. Applying it is
one `nixos-rebuild switch`.

There is no Docker, no devcontainer CLI and no code-server in here yet.

---

## Quick start

Full walkthrough with every VirtualBox setting: **[docs/BOOTSTRAP.md](docs/BOOTSTRAP.md)**.
The short version:

1. **VirtualBox GUI** — new VM, two disks (`system.vdi` 40 GB on SATA port 0,
   `persist.vdi` 80 GB on SATA port 1), BIOS firmware (*not* EFI), NAT adapter
   with the port forwards below, NixOS 26.05 minimal ISO attached. The ports are
   load-bearing: the config identifies each disk by slot, not by name or size.
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

## Using a codespace

Apply Phase 2 first (`sudo nixos-rebuild switch --flake /persist/dev-vm#dev`),
then:

```bash
codespace up github.com/you/project   # clone, build, start editor
codespace list                        # what exists, on which port
codespace down project                # stop it
codespace rebuild project             # recreate the container from scratch
codespace logs project                # editor log, when the URL will not load
```

`up` takes a git URL, a path, or the name of an existing codespace, so after the
first time `codespace up project` is enough. Repos are cloned to
`/persist/repos/<name>`.

Each codespace keeps a **sticky port** in the 8001-8010 range, recorded under
`/persist/codespace/<name>/`, so a bookmark stays valid across a down/up. Open
the printed `http://localhost:<port>/` in Firefox; the password is shared with
the hub editor and is printed by `up`.

### The hub editor

`http://localhost:8000/` is code-server running on the VM itself, for managing
repos and editing this flake. Its password is generated on first boot, logged to
the journal once, and stored in `/persist/code-server/pw`:

```bash
cat /persist/code-server/pw
journalctl -u code-server-password
```

Extensions and editor state live under `/persist/code-server/`, so they survive
a wipe of `system.vdi`.

### Git inside containers

Containers get credentials one of two ways, checked in this order:

1. **A key under `/persist/git`** — bind-mounted to `/mnt/git-ssh`, with
   `GIT_SSH_COMMAND` pointed at it. Preferred, because the path is stable.
   ```bash
   ssh-keygen -t ed25519 -f /persist/git/id_ed25519
   cat /persist/git/id_ed25519.pub    # add as a deploy key or account key
   ```
2. **A forwarded SSH agent** — used if `$SSH_AUTH_SOCK` is live and no key file
   exists. It leaks no key at all, but `$SSH_AUTH_SOCK` lives in a per-session
   directory: a container created in one SSH session holds a mount to a socket
   that is dead by the next login. `codespace rebuild` fixes it.

Neither mount is read-only, which is a deviation from `CLAUDE.md` §8. The CLI
validates `--mount` strictly as `type/source/target/external` and **rejects
`readonly`** — verified against 0.87.0. `/persist/git` is therefore a dedicated
directory holding only the git key, rather than all of `~/.ssh` or the host keys
in `/persist/ssh`, which are root-owned and useless for git anyway.

The launcher reports which mechanism a container actually has, read back from
its mounts rather than from what the host offered — `devcontainer up` reuses an
existing container and silently ignores changed `--mount` flags.

### Dotfiles

Optional, and deliberately not Nix (`CLAUDE.md` §6). Create
`/persist/codespace/config`:

```bash
DOTFILES_REPOSITORY=https://github.com/you/dotfiles
DOTFILES_INSTALL_COMMAND=install.sh
```

The launcher passes these to `devcontainer up`, the same mechanism real
Codespaces uses, so the repo stays portable. Target Debian/Ubuntu userland.

### What the launcher does that the CLI cannot

- **Publishing a port.** `devcontainer up` has no `--publish`, and `appPort`
  only exists inside a project's own `devcontainer.json` — which must stay
  portable. So a `codespace-proxy@<name>` systemd unit runs `socat` from the
  allocated port to the container's bridge address, resolved at start time
  because it changes whenever the container is recreated.
- **Installing the editor.** No third-party code-server devcontainer feature
  resolves on ghcr, so the launcher installs it after every `up` with the
  official script in `--method standalone` mode: no apt, works on any glibc base
  image, and leaves the project's `devcontainer.json` untouched. Recreating a
  container discards it, hence the reinstall.
- **Stopping.** The CLI has `up`, `exec` and `build` but no `down`, so
  `codespace down` stops the container directly and stops the proxy unit.

Extensions come from **Open VSX**, not Microsoft's marketplace: no Pylance, no
official C/C++ extension. Pick equivalents in `devcontainer.json`
`customizations`.

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
/persist/docker/         Docker's data-root: images, volumes, containers
/persist/codespace/      per-codespace port allocation + launcher config
/persist/code-server/    hub editor password, extensions, editor state
/persist/git/            the SSH key containers push with
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
| `127.0.0.1:8000` | 8000 | Hub code-server |
| `127.0.0.1:8001-8010` | 8001-8010 | Per-container editors |

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
  disko.nix                     system.vdi  (SATA port 0) — disposable
  disko-persist.nix             persist.vdi (SATA port 1) — separate file so it
                                can be left out of a reinstall
modules/
  persist.nix                   /persist wiring: host keys, home, tmpfiles
  docker.nix                    Docker, data-root on /persist, autoprune
  code-server.nix               hub editor + first-boot password generation
  codespace.nix                 launcher package + the editor proxy unit
scripts/codespace               the launcher (built by modules/codespace.nix)
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
- **Firefox keybinds.** `Ctrl+Shift+P` opens a Private Window, not the command
  palette — use `F1`. `Ctrl+W` closes the tab and the editor with it. Firefox has
  no desktop PWA support; for a chrome-less window use
  `firefox --kiosk -P codespace http://localhost:8001`.
- **Marketplace.** `code-server` uses Open VSX, not Microsoft's, so there is no
  Pylance and no official C/C++ extension.
- **A stopped codespace can be pruned.** `docker system prune` also deletes
  stopped containers, and `codespace down` stops rather than removes, so the
  weekly autoprune is filtered to `until=168h`. A codespace left down for over a
  week gets rebuilt on the next `up`; the workspace itself is a bind mount and
  is never at risk.

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
