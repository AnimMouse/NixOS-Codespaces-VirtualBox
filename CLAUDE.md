# CLAUDE.md

Project context for building a self-hosted, browser-based development environment
modelled on GitHub Codespaces.

---

## 1. Goal

A headless NixOS VM running under VirtualBox on a Windows host, exposing
per-project dev containers with `code-server` editors reachable from Firefox on
`http://localhost:<port>`.

The VM is reproducible from this git repo. The dev containers are disposable and
follow the standard Dev Container specification, so `devcontainer.json` files
remain portable to real Codespaces.

**Success criterion:** the VM can be deleted and rebuilt from the official NixOS
ISO plus this repo, with no manual configuration beyond the bootstrap sequence in
§7, and no loss of work.

---

## 2. Host environment — read before proposing anything

| Fact | Consequence |
|---|---|
| Host OS is Windows | No Nix, no `nixos-rebuild` from the host |
| Hyper-V, VBS, Memory Integrity, WSL2, Windows Sandbox all **deliberately disabled** | Do not suggest WSL2 or Docker Desktop. Both are unavailable by design |
| `bcdedit /set hypervisorlaunchtype off` is set | VirtualBox gets real VT-x. Preserve this |
| Type-2 hypervisor chosen so gaming performance is unaffected | Do not propose Hyper-V, or anything requiring it |
| Browser is Firefox / Gecko | User dislikes Electron. Never propose VS Code Desktop, Cursor, or any Electron editor as the primary interface |

Because there is no Nix on Windows, **images cannot be built locally.** This is
the single most important constraint driving §3.

---

## 3. Locked architectural decisions

These are settled. Do not re-open them unless the user explicitly asks.

### Distro: NixOS (stable 26.05 "Yarara")
Chosen over Ubuntu because the whole machine is declared in this repo rather than
converged toward by a script. Toolchains live in containers, so NixOS's FHS
incompatibility is a non-issue here.

### Provisioning: official minimal ISO + `disko` + `nixos-install --flake`
**Not** a custom ISO. **Not** a custom OVA. Both require a Linux+Nix builder,
which the host cannot provide. The official ISO never goes stale; a custom image
would need rebuilding on every config change.

### Containers: `@devcontainers/cli` + Docker
**Not** Coder self-hosted. Coder's own recommended path is the same CLI; its
added value (RBAC, quotas, audit, shared templates, Terraform provisioning) is
multi-user and worthless for a single developer, while costing a `coderd` +
Postgres footprint in a VM being kept lean.

Containers need no nested virtualisation — Docker on Linux is namespaces and
cgroups. Ubuntu/Debian/Alpine containers run natively on the NixOS kernel.

### Editor: `code-server` inside each dev container
Installed via a devcontainer feature or `postCreateCommand`. Consequence: language
servers and debuggers run on normal FHS userland, so **`nix-ld` is not needed**.

An optional hub `code-server` on port 8000 runs on the VM itself for repo
management and editing this flake.

### Networking: NAT + port forwards bound to `127.0.0.1`
**Never propose a host-only adapter.** `http://localhost` is a browser secure
context; `http://192.168.56.x` is not, which breaks the Clipboard API, service
workers, and several code-server features.

| Host | Guest | Purpose |
|---|---|---|
| `127.0.0.1:2222` | 22 | SSH / rebuilds |
| `127.0.0.1:8000` | 8000 | Hub code-server |
| `127.0.0.1:8001-8010` | 8001-8010 | Per-container editors |

Distinct ports, not subdomain routing — `*.localhost` resolution is inconsistent
across platforms and not worth debugging.

### Storage: two virtual disks
| Disk | Mount | Contents | On rebuild |
|---|---|---|---|
| `system.vdi` (~40 GB) | `/` | Nix store, OS | Delete freely |
| `persist.vdi` (~80 GB) | `/persist` | repos, Docker data, SSH keys, secrets | **Keep** |

Everything precious lives in exactly two places: `/persist`, and GitHub.

### Rebuild loop: driven from inside the VM
```powershell
ssh -p 2222 dev@localhost 'sudo nixos-rebuild switch --flake /persist/dev-vm#dev'
```
**Do not propose `--target-host`.** It requires Nix on the host machine.

---

## 4. Non-goals

- No X11, Wayland, or desktop environment in the VM. CLI only.
- Do not script VM creation or NAT rules. **The user does this in the VirtualBox
  GUI by choice.** Document the required settings; do not generate `VBoxManage`
  scripts unless asked.
- Do not Nix-ify the container-layer dotfiles (see §6).
- Do not add Coder, Kubernetes, envbuilder, or Podman.

---

## 5. Repository layout

As built. Differences from the original sketch are noted.

```
flake.nix                      # nixpkgs 26.05 + disko + home-manager
flake.lock
hosts/dev/
├── configuration.nix          # top-level machine config
├── disko.nix                  # system.vdi  — SATA port 0
└── disko-persist.nix          # persist.vdi — SATA port 1, SEPARATE on purpose
paths.nix                      # where identity/key material live — paths, no values
modules/
├── persist.nix                # /persist wiring, host key persistence
├── tools.nix                  # the `rebuild` and `ssh-auth` commands
├── docker.nix                 # Docker + devcontainer CLI
├── code-server.nix            # hub editor + first-boot password generation
├── codespace.nix              # launcher package + editor proxy unit
└── home.nix                   # home-manager wiring + git identity units
home/dev.nix                   # home-manager: VM-layer dotfiles
scripts/
├── codespace                  # launcher: up / new / rebuild / down / rm / list / logs
├── rebuild                    # rebuild [--pull]
├── ssh-auth                   # unlock the git key into the agent
└── codespace-kiosk.ps1        # Windows-side Firefox kiosk launcher
docs/BOOTSTRAP.md              # the §7 sequence, for humans
.github/workflows/build-ova.yml  # PHASE 4 ONLY — stubbed
```

Two files the sketch did not have, both earning their place:

- **`disko-persist.nix`** is separate so the persist disk can be left out of a
  reinstall. See §7.
- **`modules/codespace.nix`** separates the launcher layer from the container
  runtime in `docker.nix`.

---

## 6. Dotfiles — two separate layers, deliberately

**VM layer:** home-manager, declared in `home/dev.nix`. Shell, tmux, git config
for the VM itself.

**Neither layer holds your name or email.** Those live in a gitconfig fragment
at `/persist/git/identity`, which the VM's git config `include`s and the
launcher mounts into every container. One file, both layers, nothing personal
committed to a public repo, and no way for the two to disagree about who
authored a commit. `paths.nix` records the location and no values.

**Container layer:** a *separate* GitHub repo of plain bash, using the same
mechanism GitHub Codespaces uses. The launcher passes:

```bash
devcontainer up \
  --workspace-folder "$REPO" \
  --dotfiles-repository https://github.com/USER/dotfiles \
  --dotfiles-install-command install.sh
```

Target Debian/Ubuntu userland, **not** Nix. That portability is the entire point:
the same repo works here, in real Codespaces, and in any random container.

`install.sh` runs on every container create — keep it fast and idempotent.

Do not commit dot-prefixed files at the repo root alongside an install script;
some tooling auto-copies them without overwriting defaults, producing confusing
shell breakage. Store them undotted and symlink from `install.sh`.

---

## 7. Bootstrap sequence

Steps 1–2 are manual GUI work by the user. The repo must support 3 onward.

1. Create VM in VirtualBox GUI: 2 disks, NAT + port forwards from §3, attach ISO
2. Boot with a GUI window (headless gives no console to type at)
3. On the VM console:
   ```bash
   passwd                      # mandatory — sshd rejects empty passwords
   sudo systemctl start sshd   # enabled in config but NOT started at boot
   ```
4. From Windows Terminal: `ssh -p 2222 nixos@localhost`
5. Install. **Two entry points, because `disko --mode destroy,format,mount` is
   unconditional and a single target covering both disks would erase `/persist`
   on every reinstall — contradicting §3.**
   ```bash
   # first install only — erases BOTH disks
   sudo nix --experimental-features "nix-command flakes" run \
     github:nix-community/disko -- --mode destroy,format,mount \
     --flake github:USER/dev-vm#first-install

   # reinstall onto a fresh system.vdi — erases the system disk only
   #   ...#dev, then: sudo mount /dev/disk/by-label/persist /mnt/persist

   sudo nixos-install --flake github:USER/dev-vm#dev
   ```
   Prompts for a root password at the end. Do not skip it.

   Do not skip the disko step. Without it `/mnt` is a directory on the ISO
   overlay, `nixos-install` runs to completion anyway, and dies at the very end
   with `Failed to get blkid info (returned 512) for  on  ` — the blank fields
   being the only clue.
6. **Eject the ISO**, then reboot
7. `ssh-keygen -R "[localhost]:2222"` on the host, then SSH back in
8. `codespace up github.com/USER/project`
9. Open the printed URL in Firefox
10. Work, commit, push
11. `codespace down`

Expect 20–40 minutes for step 5, almost entirely downloads.

---

## 8. Known gotchas — encode these as fixes, not documentation

| Gotcha | Required handling |
|---|---|
| **Lockout.** A user with `isNormalUser` but no `hashedPassword`/`hashedPasswordFile`/`authorizedKeys` produces an unloggable machine after reboot | Config must declare auth. Add an assertion if practical |
| **known_hosts collision.** ISO and installed system share `localhost:2222` with different keys | Persist host keys to `/persist/ssh/`. Then it happens once, ever |
| **Git credentials.** Codespaces injects a token; nothing does that locally, so `git push` fails inside containers | Mount `/persist/git` (the git key only) into containers from the launcher, and inject `GH_TOKEN` from the VM's `gh`. Not `/persist/ssh`, and not read-only — see below |
| **Secrets in a public repo.** Password hashes must not be committed | Generate a random code-server password on first boot if `/persist/code-server/pw` is absent; log it to the journal |
| **No `devcontainer down`.** The CLI has `up`, `exec`, `build` — no down/stop | The `codespace` wrapper implements `down` via `docker stop` |
| **Docker image sprawl** | `virtualisation.docker.autoPrune.enable = true`, and Docker's `data-root` set to `/persist/docker` (a bind mount would need its source to exist before systemd mounts it) |
| **Firefox keybinds.** `Ctrl+Shift+P` opens a Private Window, not the command palette. `Ctrl+W` closes the tab and the editor with it. Firefox has no desktop PWA support | Document `F1` for the palette. Ship a kiosk launcher: `firefox --kiosk -P codespace http://localhost:PORT` |
| **Marketplace.** code-server uses Open VSX, not Microsoft's. No Pylance, no official C/C++ extension | Pick Open VSX equivalents in `devcontainer.json` `customizations` |
| **Turtle icon** in the VirtualBox status bar means Hyper-V leaked back and VirtualBox fell back to the Windows Hypervisor Platform API | Flag loudly to the user; performance drops 2–5× |

### Found while building 1–3 — all encoded as fixes

| Gotcha | Handling |
|---|---|
| **`/dev/sdX` is not stable.** Letters follow probe order, not SATA port, and differ between the ISO and the installed system | Address disks by `by-path`. Never by letter, never by `by-id` |
| **`disko --mode destroy,format,mount` is unconditional** — one target covering both disks erases `/persist` on every reinstall | Two `diskoConfigurations`: `#dev` (system only) and `#first-install` (both) |
| **Skipping disko still "works".** `nixos-install` runs to completion on an unmounted `/mnt` and dies on the bootloader with blank fields in the error | Pre-flight `findmnt /mnt` in BOOTSTRAP; troubleshooting entry for the exact message |
| **`devcontainer up` has no `--publish`** and `appPort` only exists in the project's own config | `codespace-proxy@<name>` systemd unit running `socat` to the container's bridge address, re-resolved at start |
| **No third-party code-server feature resolves on ghcr** (`devcontainers-extra`, `-contrib`, `-community`, `itsmechlark` all return no manifest) | Install it after every `up` with the official script, `--method standalone`. Only `devcontainers/*` features are dependable |
| **`code-server` with no path argument** opens no folder: empty tree, terminals in `$HOME` | Pass `remoteWorkspaceFolder` from `devcontainer up`'s stdout JSON |
| **The CLI refuses to guess a `devcontainer.json`** and most repos have none | Generate one into `/persist/codespace/<name>/` and pass `--override-config`. Never write into the checkout |
| **`--mount` rejects `readonly`** — it is validated as `type/source/target/external` only | Mount a directory holding only the git key, not `~/.ssh` and not the host keys |
| **`--remote-env` and `--secrets-file` do not persist.** They apply to that invocation's user commands, not to the container environment | Put anything long-lived on the code-server process and in `/etc/profile.d`; secrets in a `0600` file sourced from there |
| **The dotfiles clone runs inside the container, first**, before any credential this repo sets up exists — a private repo fails and `up` still reports success | Pass `GIT_SSH_COMMAND` and an https→ssh rewrite via `--remote-env`, which *does* reach that clone |
| **nixpkgs bash has no `compgen`** — built without programmable completion, so it returns 127 and the branch silently reads false. shellcheck does not catch it | Glob into an array and test `[ -e "${arr[0]}" ]` |
| **`pgrep -f` inside `sh -c` matches itself**, because the pattern is in the shell's own command line | Bracket the first character: `[c]ode-server` |
| **`docker system prune` deletes stopped containers**, and `codespace down` stops rather than removes | `autoPrune.flags = [ "--filter" "until=168h" ]` |
| **Anything in `install.sh` that waits for input hangs the container create forever.** The tooling runs it with a tty, so `ssh-keygen` on an encrypted key prompts — and with stderr discarded the prompt is invisible. It looks like `codespace up` stopping dead at "Executing command ./install.sh..." | Force every `ssh-keygen` non-interactive: `-P ""`, `SSH_ASKPASS_REQUIRE=never`, stdin closed. Never configure signing with a key that cannot be used without a prompt |
| **Reference checkouts.** In real Codespaces `/workspaces` persists, so cloning a repo beside the project for reference works; here it would vanish | `/persist/refs` is mounted at `/workspaces/refs` in every container — same shape, survives, shared. `CONTAINER_REFS=0` disables it |
| **Only `/workspaces/<name>` is a mount.** A sudo-created sibling under `/workspaces`, or anything in `$HOME`, lives in the container layer and dies with it — while looking exactly like the real workspace | `/workspaces` stays root-owned so a plain clone there fails rather than silently landing in the container. `rebuild` and `rm` list non-mount entries under `/workspaces` before discarding the container |
| **`git config --global` cannot work on this VM** — home-manager owns `~/.config/git/config` as a symlink into the read-only store, so it fails with `could not lock config file`. git's own "please tell me who you are" advises exactly that command | Seed `/persist/git/identity` on first boot with comments only — no placeholder values, so an unedited VM has no identity rather than a fake one — and put the `git config -f` commands that do work in those comments |
| **A proxy unit that fails a few times hits systemd's default start rate limit** (5 in 10s) and then refuses `systemctl restart` until `reset-failed` — presenting as "the editor did not answer" with a perfectly healthy editor | `StartLimitIntervalSec = 0` on the template unit; `reset-failed` before `restart` in the launcher, and check the exit status. On timeout, probe the container directly so the message names the guilty half |
| **A passphrase-protected key cannot be used where nothing can prompt** — and ssh reports it as `Permission denied (publickey)`, identical to an unregistered key | A user ssh-agent (`services.ssh-agent` + `users.users.dev.linger`) at the stable `/run/user/1000/ssh-agent`; the launcher forwards the socket, never the key. It detects a locked key with `ssh-keygen -y -P ""` and names the `ssh-add` to run rather than letting git fail opaquely |

---

## 9. Build order

**Phase 1 — bootable machine. DONE, proven on hardware.** `flake.nix`,
`disko.nix`, `configuration.nix` with users/SSH/persist. Installs from the ISO,
reboots, accepts SSH, and `/persist` survived a full `system.vdi` delete and
reinstall with the marker file intact and no host-key change.

**Phase 2 — container plumbing. DONE, running on the VM.** Docker, devcontainer
CLI, the `codespace` launcher, port allocation, hub editor. A dev container comes
up and its editor is reachable in Firefox, for repos with and without a
`devcontainer.json`.

**Phase 3 — personalisation. DONE.** home-manager (`home/dev.nix`), GitHub auth
and commit signing over SSH, the portable container dotfiles repo, and the
Windows kiosk launcher.

**Phase 4 — optional, not started.** GitHub Actions building an OVA via
`nix build .#vbox` so recreates drop from ~30 minutes to ~2. Phase 1 is now
proven, so the precondition is met.

### Decisions taken during 1–3 that amend the sections above

- **Disks are addressed by SATA slot** (`/dev/disk/by-path/pci-0000:00:1f.2-ata-N`),
  never `/dev/sdX`. The kernel assigned letters in probe order, not port order,
  and differently on the ISO than on the installed system — which pointed both
  the partitioner and `grub-install` at the wrong disk. Not `by-id` either: that
  encodes the `.vdi`'s serial, which changes every time `system.vdi` is recreated.
- **BIOS/GRUB, not UEFI.** VirtualBox's EFI loses its boot entry too often, and
  a headless VM gives no way out of the EFI shell.
- **Two disko entry points** (§7).
- **Docker uses `data-root`, not a bind mount** of `/var/lib/docker`. A bind
  mount needs its source to exist before systemd mounts it; `dockerd` creates
  `data-root` itself.
- **Containers get `/persist/git`, not `/persist/ssh`,** and not read-only. The
  CLI validates `--mount` as `type/source/target/external` and rejects
  `readonly`; `/persist/ssh` holds root-owned host keys that containers cannot
  read and should not have.
- **One SSH key does authentication and signing.** No PAT. `gh` is installed for
  the API only.

---

## 10. Working agreements

- Prefer NixOS modules over `system.activationScripts` or hand-written units.
- Pin nixpkgs in `flake.lock`. Never use `nixos-unstable` without being asked.
- Verify option names against the installed nixpkgs (`nix repl`, or
  `search.nixos.org` for 26.05) rather than from memory. `services.code-server`
  options have shifted across releases.
- Every module gets a comment explaining *why*, not what.
- If a decision in §3 looks wrong given something newly discovered, say so
  explicitly and explain the tradeoff. Don't silently substitute an alternative.
