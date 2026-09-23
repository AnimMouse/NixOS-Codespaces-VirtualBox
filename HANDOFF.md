# HANDOFF — moving development onto the VM

This repo was built and verified from a **GitHub Codespace**, not from the VM it
describes. Everything through Phase 3 is done and pushed; Phase 4 is untouched.
This file is what you need to carry on from inside the VM itself.

Read `CLAUDE.md` for the design and the gotcha list — it is the authority and is
current. This file only covers what *changes* when the workbench moves.

---

## Where things stand

| | |
|---|---|
| HEAD at handoff | `bb6607f` — in sync with `origin/main` |
| Phases 1–3 | Done. Installed, booted, and in daily use on the VM |
| Phase 4 (OVA in CI) | Not started. `.github/workflows/build-ova.yml` is a dispatch-only stub |
| nixpkgs | `nixos-26.05` pinned at `c5c4a43b0e`; disko `ff8702b4de`; home-manager `fd0956c99c` |
| Sibling repo | `AnimMouse/dotfiles-codespaces` — container dotfiles, also current |

**Nothing in this repo is personal.** Your name, email and keys live on
`/persist`, never in git. `paths.nix` records the locations and no values.

---

## What the move actually changes

The Codespace could build and evaluate everything, but it could not *run* the
system. That asymmetry shaped how things were tested, and it disappears now.

### Things that were never tested, and now can be

These were built from documentation and inspection only:

- **Every systemd unit.** The Codespace had no systemd at all (PID 1 was
  `docker-init`). `code-server`, `code-server-password`, `codespace-proxy@`,
  `git-allowed-signers`, `git-identity-template`, `github-known-hosts` were all
  verified by reading the generated unit files, never by running them.
- **The editor proxy.** Every launcher test used a fake `sudo systemctl` that
  ran `socat` directly. The real template unit's behaviour under failure,
  restart and `reset-failed` is unverified.
- **The hub editor** on port 8000, and `services.code-server` as a whole.
- **The Windows side:** `scripts/codespace-kiosk.ps1` parses under pwsh and its
  URL resolution is tested, but it has never launched Firefox.
- **`ssh-auth` against the real user ssh-agent** (`services.ssh-agent` +
  lingering). Only its no-key / no-agent / already-loaded branches were tested.

If you touch any of these, you can now test them properly rather than by proxy.

### Test scaffolding you no longer need

Ignore these patterns if you see them in the history — they were workarounds for
the Codespace, not the intended way to work:

- A shim `sudo` that intercepted `systemctl`.
- A hand-made `/persist` tree under a real root filesystem.
- A local `git daemon` on `172.17.0.1:9418` to serve the dotfiles repo, because
  the dotfiles clone happens *inside* the container and cannot reach a `file://`
  path on the host.
- `script -qfec …` to get a pty, because `docker exec -it` needs one and the
  tool harness had none.

### The new hazard: you are editing the machine you are sitting on

In the Codespace a bad flake cost nothing. On the VM, `nixos-rebuild switch` can
take away sshd, networking or your login.

- Use **`rebuild --pull`** for ordinary changes.
- For anything touching users, sshd, networking or the bootloader, build first:
  `sudo nixos-rebuild test --flake /persist/dev-vm#dev` applies without touching
  the bootloader, so a reboot returns you to the last good generation.
- If a switch breaks the machine: `sudo nixos-rebuild switch --rollback`, or
  pick the previous generation from the GRUB menu on the VirtualBox console.
- **Keep the VirtualBox GUI console available** while doing risky work. It is
  the only way in if sshd stops coming up.

---

## Where to do the work

**In a codespace on the flake checkout itself.** This repo ships a
`.devcontainer/devcontainer.json` with the official Nix feature, so the
container has the full toolchain and the VM stays free of development tools.

```bash
codespace up /persist/dev-vm      # first time; afterwards: codespace up dev-vm
```

The workspace *is* `/persist/dev-vm` — the very checkout the system rebuilds
from — so what you edit in the editor is what `rebuild` applies. No pushing and
re-pulling to test a change.

The Nix store lives on a named docker volume (`dev-vm-nix-store`), so recreating
the container does not re-download nixpkgs. Evaluating this flake is about 40
seconds cold and 10 warm.

> The hub editor on `http://localhost:8000/` still works and needs no setup,
> since it runs on the VM and has Nix natively. Use whichever you prefer — the
> codespace keeps the tooling out of the VM, the hub avoids a second Nix store.

### The one thing the container cannot do

**Apply.** `nixos-rebuild switch` needs root on the VM and the VM's own store, so
the loop is:

```bash
# in the codespace terminal — edit, then verify
nix flake check
nix build .#nixosConfigurations.dev.config.system.build.toplevel --no-link

# on the VM — apply what you just verified
rebuild
```

`rebuild` without `--pull`, because the codespace edited that checkout directly.

Note the two Nix stores: the container builds into its own, so the VM builds
again when you apply. In practice the VM's store already holds almost
everything, so its rebuild is quick; the container's is the one that starts
cold, once.

### Verifying a change without applying it

All three work inside the codespace as well as on the VM:

```bash
nix flake check
nix build .#nixosConfigurations.dev.config.system.build.toplevel --no-link
nix run github:nix-community/disko -- --mode destroy,format,mount --flake .#dev --dry-run
```

`nix build` also runs `shellcheck` over `scripts/codespace`, `scripts/rebuild`
and `scripts/ssh-auth`, because they are built with `writeShellApplication`. A
shell mistake fails the build — verified inside the container by introducing a
typo and watching `SC2154` stop it.

> **Watch the warnings, not just the exit status.** Evaluation warnings print
> before the build output and scroll away. `nix build … 2>&1 | grep -i warning`
> catches renamed options early — that is how a batch of home-manager renames
> went unnoticed for several commits.

---

## Runtime state, none of it in git

```
/persist/dev-vm/                 this repo — what the system rebuilds from
/persist/repos/<name>/           project checkouts, one per codespace
/persist/refs/                   reference checkouts, mounted in every container
/persist/git/
  id_ed25519[.pub]               one key: GitHub auth AND commit signing
  identity                       [user] name/email — the only copy
  allowed_signers                generated from the key + identity
  known_hosts                    github.com, scanned once
/persist/codespace/
  config                         launcher settings (below)
  secrets                        KEY=value, mode 0600
  cache/                         shared download cache, bind-mounted in every
                                 container — the code-server tarball, once
  <name>/                        port, generated devcontainer.json, secrets, last_used
/persist/code-server/pw          hub editor password, generated on first boot
/persist/ssh/                    SSH *host* keys — the machine's identity
/persist/secrets/                spare 0700 dir, root-owned (sudo to use it)
/persist/docker/                 Docker data-root
/persist/home/dev/               the dev user's home
```

### `/persist/codespace/config`

| Key | Default | |
|---|---|---|
| `DOTFILES_REPOSITORY` | — | passed to `devcontainer up` |
| `DOTFILES_INSTALL_COMMAND` | — | usually `install.sh` |
| `DEFAULT_IMAGE` | `devcontainers/base:ubuntu` | for repos with no devcontainer.json |
| `GIT_SSH_MODE` | `auto` | `auto` \| `agent` \| `keyfile` \| `none` |
| `CONTAINER_GH_TOKEN` | `1` | inject the VM's `gh` token |
| `CONTAINER_REFS` | `1` | mount `/persist/refs` |
| `APT_MIRROR` | — | rewrite apt sources in containers |
| `RETENTION_DAYS` | `30` | days idle before `codespace gc` removes the container; `0` disables |
| `CODE_SERVER_VERSION` | `latest` | pin the editor, e.g. `4.138.0`; a leading `v` is fine. Takes effect on `codespace rebuild` |

---

## Daily commands

```bash
rebuild --pull                  # git pull, then nixos-rebuild switch
ssh-auth                        # unlock the git key into the agent, once per boot

codespace up <url|path|name>    # create/start a codespace and its editor
codespace new <name>            # the same, on an empty workspace
codespace shell <name>          # a terminal inside it, in a tmux on the VM
codespace rebuild <name>        # recreate the container, keep the port
codespace down <name>           # stop it
codespace rm <name> [opts]      # --repo drops the checkout, --volume its volumes
codespace list                  # + IDLE, the clock gc is counting
codespace logs <name>
codespace gc [--dry-run]        # what the daily timer runs; --dry-run to preview
```

After a VM reboot: `ssh-auth`, then `codespace up <name>` for each one you want
back. Containers do not auto-start, and the editor proxy is not enabled at boot.

A codespace idle longer than `RETENTION_DAYS` (default 30) loses its *container*
to the daily `codespace-gc.timer` — never its checkout, its port, or its URL.
`codespace up <name>` rebuilds it in place. Anything that lived only in the
container layer (`$HOME`, hand-installed tooling) goes, exactly as it does on
`codespace rebuild`. A codespace left *running* is never touched, however long
since you last typed in it.

---

## If you pick up Phase 4

The goal is `nix build .#vbox` producing an OVA in CI, so recreating the VM drops
from ~30 minutes to ~2. Its stated precondition — a Phase 1 proven on real
hardware — is met.

Worth deciding first: the OVA has to be built somewhere with Linux and Nix, and
that is the constraint the whole design exists to respect. GitHub Actions
satisfies it; your Windows host does not, and neither does the VM if the VM is
what you are rebuilding. Keep the official-ISO path working regardless — a
CI-built image that fails is worse than no image, which is why §9 puts this last.

---

## Loose ends

- **Docker's volume namespace is flat and global to the daemon.** Two
  `devcontainer.json` files naming the same `source=` share one volume, mounted
  into both containers at once with no coordination. This repo's `.claude` mount
  uses `${devcontainerId}` so copying the file cannot collide; the Nix store
  volume keeps a fixed name on purpose, because sharing that closure is the
  point — and it is a cache, so deleting it costs time, not data.
  `codespace rm <name> --volume` offers every volume the container had and
  reports each outcome — docker refuses to remove one another container still
  references, which is the check worth trusting. Bind mounts are never
  candidates: `docker volume rm` addresses the volume namespace, not paths.
- **`/workspaces` is not `/persist`.** Only `/workspaces/<name>` and
  `/workspaces/refs` are mounts. Anything else there, and all of `$HOME`, dies
  with the container. `rebuild` and `rm` warn before discarding.
- **`APT_MIRROR` cannot speed up devcontainer features** — they apt-install
  during the image build, before any container exists to rewrite sources in.
- **The container dotfiles are optional here** and load-bearing in real
  Codespaces. Do not fold them into this repo; that portability is the point.
- **`git config --global` does not work on the VM.** home-manager owns
  `~/.config/git/config` as a read-only store symlink. Use
  `git config -f /persist/git/identity …`.
