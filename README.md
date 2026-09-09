# NixOS-Codespaces-VirtualBox

A self-hosted GitHub Codespaces: a headless NixOS VM under VirtualBox on a
Windows host, serving per-project dev containers whose `code-server` editors you
open in Firefox at `http://localhost:<port>`.

The VM is declared entirely in this repo. Containers are disposable and follow
the standard Dev Container spec, so `devcontainer.json` files stay portable to
real Codespaces.

**All of it can be deleted and rebuilt from the official NixOS ISO plus this
repo, without losing work.** Everything precious lives in exactly two places:
`/persist`, and GitHub.

| Phase | | |
|---|---|---|
| 1 | Bootable machine, `/persist` on its own disk | **Done**, survived a `system.vdi` wipe |
| 2 | Docker, devcontainer CLI, `codespace` launcher, editors | **Done**, running |
| 3 | home-manager, GitHub auth + signing, dotfiles, kiosk | **Done** |
| 4 | CI-built OVA to skip the 30-minute install | Not started |

---

# Setup

Four parts. Part 1 is a one-off; parts 2–4 take about ten minutes.

## 1. Install the VM

Full walkthrough, including every VirtualBox setting:
**[docs/BOOTSTRAP.md](docs/BOOTSTRAP.md)**. The shape of it:

| | |
|---|---|
| VM | 8 GB RAM, 4 CPUs, **BIOS firmware — leave "Enable EFI" unchecked** |
| Disk on SATA port **0** | `system.vdi`, 40 GB — disposable |
| Disk on SATA port **1** | `persist.vdi`, 80 GB — **keep this one** |
| Network | NAT, with the port forwards below, each bound to `127.0.0.1` |

The ports are load-bearing: the config identifies disks by SATA slot, not by
name or size.

| Host | Guest | |
|---|---|---|
| `127.0.0.1:2222` | 22 | SSH |
| `127.0.0.1:8000` | 8000 | Hub editor |
| `127.0.0.1:8001-8010` | 8001-8010 | One per codespace |

Then, from the NixOS ISO:

```bash
# ERASES BOTH DISKS — first install only
sudo nix --experimental-features "nix-command flakes" run \
  github:nix-community/disko -- --mode destroy,format,mount \
  --flake github:AnimMouse/NixOS-Codespaces-VirtualBox#first-install

sudo nixos-install --flake github:AnimMouse/NixOS-Codespaces-VirtualBox#dev
```

Eject the ISO, reboot, then from Windows Terminal:

```powershell
ssh -p 2222 dev@localhost      # password: dev
```

## 2. Set up the rebuild loop

Clone this repo where the running system expects it:

```bash
sudo git clone https://github.com/AnimMouse/NixOS-Codespaces-VirtualBox /persist/dev-vm
sudo chown -R dev:users /persist/dev-vm
passwd                          # change the default password
```

## 3. GitHub: one SSH key for everything

GitHub keeps authentication keys and signing keys in separate lists but accepts
the same public key in both. So one key pushes, pulls **and** signs — no token to
rotate, and it is already mounted into every container.

```bash
ssh-keygen -t ed25519 -C "dev@nixos-vm" -f /persist/git/id_ed25519
cat /persist/git/id_ed25519.pub
```

Add that key at <https://github.com/settings/keys> **twice**:

- once as an **Authentication key**
- once as a **Signing key**

> Already signing commits elsewhere? Copy that private key to
> `/persist/git/id_ed25519` instead of generating a new one, and your whole
> history keeps verifying under a single key.

Then check it and log in to `gh` for API work:

```bash
ssh -T git@github.com                     # "Hi <you>! You've successfully authenticated"
sudo systemctl restart git-allowed-signers
gh auth login                             # device flow: open the URL in Firefox on Windows
```

## 4. Point the launcher at your dotfiles

Optional. Create `/persist/codespace/config`:

```bash
DOTFILES_REPOSITORY=https://github.com/AnimMouse/dotfiles-codespaces
DOTFILES_INSTALL_COMMAND=install.sh
```

Private repos work — the launcher hands the clone your SSH key. See
[Dotfiles](#dotfiles).

That is the whole setup. `codespace up <repo>` from here.

---

# Daily use

## Working on a project

```bash
codespace up github.com/you/project   # clone, build, start the editor
codespace new scratch                 # no repo — just an empty workspace
codespace list                        # what exists, on which port
codespace down project                # stop it; container kept
codespace up project                  # start it again, same port
codespace rm project                  # delete the container, keep the checkout
```

`up` takes a git URL, a path, or the name of an existing codespace — so after
the first time, `codespace up project` is enough. Repos are cloned to
`/persist/repos/<name>`.

Each codespace keeps its **port** in `/persist/codespace/<name>/`, so a bookmark
stays valid across a `down`/`up`. Open the printed `http://localhost:<port>/`;
the password is shared with the hub editor and printed by `up`.

| Command | What it does |
|---|---|
| `codespace up <url\|path\|name>` | Create or start it, and its editor |
| `codespace new <name>` | The same, on an empty workspace — no repo to clone |
| `codespace rebuild <name>` | Recreate the container from scratch, same port |
| `codespace down <name>` | Stop it. Fast to restart, keeps installed packages |
| `codespace rm <name>` | Delete the container and its port. **Keeps the checkout** |
| `codespace rm <name> --repo` | …and delete `/persist/repos/<name>` too |
| `codespace list` | Name, port, state, URL |
| `codespace logs <name>` | Editor log, when the URL will not load |

`down` versus `rm`: `down` is closing the lid, `rm` is throwing the machine
away. Both leave your code alone.

**A blank codespace** — for scratch work, trying a language, or anything with no
repo yet — is `codespace new <name>`. It creates an empty `/persist/repos/<name>`
and brings a container up on it, using the default image. Deliberately no
`git init`: run one yourself if you want the directory to become a repo. Running
it again on an existing name just starts that codespace, so it is safe to repeat.

Use `rebuild` after changing a `devcontainer.json`, or after adding an SSH key
that a running container was created without.

## Rebuilding the VM

After changing anything in this repo:

```bash
cd /persist/dev-vm && git pull
sudo nixos-rebuild switch --flake /persist/dev-vm#dev
```

or just `rebuild` inside the VM — same thing. From Windows, without logging in:

```powershell
ssh -p 2222 dev@localhost 'sudo nixos-rebuild switch --flake /persist/dev-vm#dev'
```

Passwordless sudo for `wheel` exists precisely so that non-interactive form
works: `ssh host 'sudo ...'` gets no TTY and cannot answer a prompt.

To roll back a bad rebuild: `sudo nixos-rebuild switch --rollback`, or pick an
older generation from the GRUB menu.

## The hub editor

`http://localhost:8000/` is code-server on the VM itself — for managing repos
and editing this flake. It has the real Nix toolchain; a dev container does not.

```bash
cat /persist/code-server/pw       # the password, generated on first boot
```

Extensions and editor state live under `/persist/code-server/`, so they survive
a `system.vdi` wipe.

## Kiosk windows

Firefox has no desktop PWA support, and in a normal tab `Ctrl+W` closes the
editor with it. Run this **on Windows**:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\codespace-kiosk.ps1            # hub
powershell -ExecutionPolicy Bypass -File .\scripts\codespace-kiosk.ps1 8002
powershell -ExecutionPolicy Bypass -File .\scripts\codespace-kiosk.ps1 project
```

A name is resolved by asking the VM over SSH. `F11` leaves kiosk mode, `Alt+F4`
closes. Inside the editor, **`F1` is the command palette** — `Ctrl+Shift+P`
opens a Firefox private window.

---

# How the pieces fit

## GitHub authentication

| | |
|---|---|
| **SSH** | Used for everything git. No expiry, and it signs commits too |
| **PAT** | Not used. Expires, cannot sign, and invites being pasted into a remote URL |
| **OAuth (`gh`)** | The API only — `gh pr create`, `gh repo create`. Git stays on SSH |

The VM rewrites GitHub https URLs to SSH:

```
[url "git@github.com:"]
	insteadOf = https://github.com/
```

That is what lets `codespace up github.com/you/private-repo` work — the launcher
clones the https form and git quietly authenticates with the key.

**Containers** get `/persist/git` bind-mounted at `/mnt/git-ssh`, so they push
and sign with the same key. Nothing is copied into the container.

**`gh` in containers.** On the VM the login lives in `~/.config/gh`, which is on
`/persist` — so it survives a reboot *and* a `system.vdi` wipe. Containers have
their own `$HOME` and inherit nothing, so `codespace up` reads `gh auth token`
on the VM and hands the container `GH_TOKEN`, the same trick real Codespaces
uses. It is read at `up` time, so re-run `codespace up` after re-authenticating.
`CONTAINER_GH_TOKEN=0` in the launcher config turns it off.

> `gh` itself is not in most base images — add
> `ghcr.io/devcontainers/features/github-cli:1` to the devcontainer config.

> Network blocking outbound port 22? Add to `~/.ssh/config`: `Host github.com` /
> `Hostname ssh.github.com` / `Port 443`.

## Dotfiles

Two layers, deliberately separate.

**VM layer** — `home/dev.nix`, via home-manager: git identity and signing, SSH
config, `gh`, bash aliases, tmux, direnv. Applied by `nixos-rebuild switch`.

**Container layer** — a separate repo of plain bash, the same mechanism real
Codespaces uses, so one repo works in both places. It finds its signing key in
this order:

1. `/mnt/git-ssh/id_ed25519` — this VM's mount; used in place
2. `$SSH_ANIMMOZ_KEY` — a Codespaces secret
3. neither — signing off, so commits still succeed

**Private dotfiles repos work.** Worth knowing why that needed doing: the
dotfiles clone runs *inside* the container and is the first thing to run there,
before any credential exists. A private repo over https fails with `could not
read Username`, and `devcontainer up` **still reports success** — so you get a
container with no dotfiles and no error. `codespace up` fixes it by passing that
clone the mounted key and an https→ssh rewrite.

> Simpler alternative: dotfiles rarely contain secrets, and a public repo
> sidesteps this entirely.

Store dot-files **undotted with an `install.sh`**. A repo of dot-prefixed files
with no install script gets auto-linked instead — but only where the base image
has no file of that name, so an image shipping its own `.gitconfig` silently
wins and your config just never applies.

## Repos without a devcontainer.json

Most repos have none, and the CLI refuses to guess. The launcher writes a
default to `/persist/codespace/<name>/devcontainer.json` and passes it as
`--override-config`. Nothing is added to your checkout; edit that file and
`codespace rebuild`.

Change the default image for new codespaces in `/persist/codespace/config`:

```bash
DEFAULT_IMAGE=mcr.microsoft.com/devcontainers/base:ubuntu-24.04
```

It is used **only while the repo has no config of its own**. Commit a real
`.devcontainer/devcontainer.json` and it takes over on the next rebuild.

## What lives where

| Disk | Mount | On rebuild |
|---|---|---|
| `system.vdi` (40 GB) | `/` | Delete freely |
| `persist.vdi` (80 GB) | `/persist` | **Keep** |

```
/persist/dev-vm/         this repo, for the rebuild loop
/persist/repos/          project checkouts
/persist/git/            the SSH key, allowed_signers, known_hosts
/persist/ssh/            SSH host keys — machine identity, not yours
/persist/home/dev/       the dev user's home (/home/dev symlinks here)
/persist/docker/         images, volumes, containers
/persist/codespace/      per-codespace port + config, launcher config
/persist/code-server/    hub editor password, extensions, state
/persist/secrets/        anything else, mode 0700
```

`/persist` is `neededForBoot`, so a detached `persist.vdi` is a hard boot
failure by design rather than new state landing quietly on the disposable disk.

## Reinstalling — two disko targets

`disko --mode destroy,format,mount` is unconditional, so the disks are exposed
as two separate targets:

| Target | Formats | When |
|---|---|---|
| `#first-install` | **Both disks** | First install, or a deliberate clean slate |
| `#dev` | `system.vdi` only | Every reinstall |

`#first-install` mounts `/mnt/persist` for you; `#dev` does not, so the
reinstall path needs `sudo mount /dev/disk/by-label/persist /mnt/persist` before
`nixos-install`. Skipping it puts `/persist/home/dev` on the *system* disk, where
it is shadowed the moment the real disk mounts.

## Repo layout

```
flake.nix                       nixpkgs 26.05 + disko + home-manager
hosts/dev/
  configuration.nix             boot, network, sshd, users, nix
  disko.nix                     system.vdi  — SATA port 0
  disko-persist.nix             persist.vdi — SATA port 1, separate on purpose
modules/
  persist.nix                   /persist wiring, host keys, home
  docker.nix                    Docker, data-root on /persist, autoprune
  code-server.nix               hub editor + first-boot password
  codespace.nix                 launcher package + editor proxy unit
  home.nix                      home-manager wiring + git identity units
home/dev.nix                    VM dotfiles: git, ssh, gh, bash, tmux
scripts/codespace               the launcher
scripts/codespace-kiosk.ps1     Windows Firefox kiosk launcher
docs/BOOTSTRAP.md               full install walkthrough
CLAUDE.md                       design decisions and constraints
```

---

# Why it is built this way

The Windows host has Hyper-V, VBS, WSL2 and Windows Sandbox deliberately off, so
VirtualBox gets real VT-x and gaming performance is unaffected. **There is no Nix
on the host**, and that one fact drives most of the design:

- **Official ISO + disko + `nixos-install --flake`**, not a custom ISO or OVA —
  both need a Linux+Nix builder the host cannot provide.
- **Rebuilds run inside the VM**, never `--target-host`, for the same reason.
- **`@devcontainers/cli` + Docker**, not Coder — Coder's own recommended path is
  this CLI, and its added value is multi-user. Containers need no nested
  virtualisation.
- **`code-server` inside each container**, so language servers run on normal FHS
  userland and `nix-ld` is unnecessary. No Electron anywhere.
- **BIOS/GRUB, not UEFI.** VirtualBox's EFI loses its boot entry too often, and a
  headless VM gives no graceful exit from the EFI shell.
- **Disks by SATA slot**, never `/dev/sdX` — the kernel assigns letters in probe
  order, differently on the ISO than on the installed system.
- **Distinct ports, not subdomain routing** — `*.localhost` resolution is
  inconsistent across platforms.
- **NAT bound to `127.0.0.1`, no host-only adapter.** `http://localhost` is a
  browser secure context; `http://192.168.56.x` is not, which breaks the
  Clipboard API and several code-server features.

The VM stays thin: no X11, no desktop, no toolchains. Those belong in containers,
which is also why NixOS's FHS incompatibility is a non-issue here.

Three things the devcontainer CLI cannot do, which the launcher fills in:
publishing a port (a `codespace-proxy@` unit runs `socat` to the container),
installing code-server (no third-party feature resolves on ghcr, so the official
install script runs after every `up`), and stopping a container at all.

---

# Troubleshooting

| Symptom | Cause |
|---|---|
| **Turtle icon** in the VirtualBox status bar | Hyper-V leaked back; performance drops 2–5×. `bcdedit /set hypervisorlaunchtype off`, reboot Windows |
| Editor URL will not load | `codespace logs <name>`, then `systemctl status codespace-proxy@<name>` |
| Terminal opens in `$HOME`, `git status` fails | Editor started without a folder. `codespace up <name>` replaces it |
| Dotfiles not applied, no error | The clone failed silently. Check the repo is reachable and the key is registered |
| Commits are not signed | `cat ~/.config/git/local` in the container — no key found. `codespace rebuild <name>` |
| `Failed to get blkid info (returned 512) for  on  ` | The disko step was skipped. `findmnt /mnt` must show a real mount |
| Boot hangs waiting for `/persist` | `persist.vdi` detached or on the wrong SATA port. Deliberately a hard stop |
| No Pylance / no official C/C++ extension | code-server uses Open VSX. Pick equivalents in `devcontainer.json` `customizations` |
| A codespace vanished after a week | `docker system prune` deletes stopped containers; the timer is filtered to `until=168h`. `codespace up` rebuilds it |

## Checking a change without a VM

```bash
nix flake check
nix build .#nixosConfigurations.dev.config.system.build.toplevel --no-link
nix run github:nix-community/disko -- --mode destroy,format,mount --flake .#dev --dry-run
```

Read `CLAUDE.md` before changing anything structural — it records which
decisions are settled and why.
