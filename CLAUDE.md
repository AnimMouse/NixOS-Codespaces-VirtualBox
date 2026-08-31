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

## 5. Repository layout to build

```
dev-vm/
├── flake.nix                  # nixpkgs 26.05 + disko
├── flake.lock
├── hosts/dev/
│   ├── configuration.nix      # top-level machine config
│   └── disko.nix              # declarative partitioning, both disks
├── modules/
│   ├── persist.nix            # /persist bind-mounts, host key persistence
│   ├── docker.nix             # Docker + devcontainer CLI
│   └── code-server.nix        # hub editor + first-boot password generation
├── home/
│   └── dev.nix                # home-manager: VM-layer dotfiles
├── scripts/
│   └── codespace              # launcher: up / down / list
├── docs/
│   └── BOOTSTRAP.md           # the §7 sequence, for humans
└── .github/workflows/
    └── build-ova.yml          # PHASE 2 ONLY — leave stubbed
```

---

## 6. Dotfiles — two separate layers, deliberately

**VM layer:** home-manager, declared in `home/dev.nix`. Shell, tmux, git config
for the VM itself.

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
5. Install:
   ```bash
   sudo nix --experimental-features "nix-command flakes" run \
     github:nix-community/disko -- --mode destroy,format,mount \
     --flake github:USER/dev-vm#dev
   sudo nixos-install --flake github:USER/dev-vm#dev
   ```
   Prompts for a root password at the end. Do not skip it.
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
| **Git credentials.** Codespaces injects a token; nothing does that locally, so `git push` fails inside containers | Mount `/persist/ssh` read-only into containers via `devcontainer.json` `mounts` |
| **Secrets in a public repo.** Password hashes must not be committed | Generate a random code-server password on first boot if `/persist/code-server/pw` is absent; log it to the journal |
| **No `devcontainer down`.** The CLI has `up`, `exec`, `build` — no down/stop | The `codespace` wrapper implements `down` via `docker stop` |
| **Docker image sprawl** | `virtualisation.docker.autoPrune.enable = true`, and `/var/lib/docker` bind-mounted to `/persist/docker` |
| **Firefox keybinds.** `Ctrl+Shift+P` opens a Private Window, not the command palette. `Ctrl+W` closes the tab and the editor with it. Firefox has no desktop PWA support | Document `F1` for the palette. Ship a kiosk launcher: `firefox --kiosk -P codespace http://localhost:PORT` |
| **Marketplace.** code-server uses Open VSX, not Microsoft's. No Pylance, no official C/C++ extension | Pick Open VSX equivalents in `devcontainer.json` `customizations` |
| **Turtle icon** in the VirtualBox status bar means Hyper-V leaked back and VirtualBox fell back to the Windows Hypervisor Platform API | Flag loudly to the user; performance drops 2–5× |

---

## 9. Build order

**Phase 1 — bootable machine.** `flake.nix`, `disko.nix`, `configuration.nix`
with users/SSH/persist. Verify: installs from ISO, reboots, accepts SSH, `/persist`
survives a `system.vdi` wipe.

**Phase 2 — container plumbing.** Docker, devcontainer CLI, the `codespace`
launcher, port allocation. Verify: an Ubuntu-based `devcontainer.json` comes up
and its editor is reachable in Firefox.

**Phase 3 — personalisation.** home-manager, the dotfiles repo, kiosk shortcuts.

**Phase 4 — optional.** GitHub Actions building an OVA via `nix build .#vbox` so
recreates drop from ~30 minutes to ~2. Do this only after Phase 1 is proven; a
CI-built image from an unproven config is worse than no image.

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
