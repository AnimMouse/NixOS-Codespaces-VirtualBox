# HANDOFF — moving development onto the VM

This repo was built and verified from a **GitHub Codespace**, not from the VM it
describes. Everything through Phase 3 is done; Phase 4 is untouched. Since the
move, work continues from the dev-vm codespace on the VM itself — see "Built
since the move" below. This file is what you need to carry on.

Read `CLAUDE.md` for the design and the gotcha list — it is the authority and is
current. This file only covers what *changes* when the workbench moves.

---

## Where things stand

| | |
|---|---|
| HEAD at handoff | `bb6607f` — where things stood when work moved off the Codespace. `git log` for now; `main` is often ahead of `origin` |
| Phases 1–3 | Done. Installed, booted, and in daily use on the VM |
| Phase 4 (OVA in CI) | Not started. `.github/workflows/build-ova.yml` is a dispatch-only stub |
| nixpkgs | `nixos-26.05` pinned at `c5c4a43b0e`; disko `ff8702b4de`; home-manager `fd0956c99c` |
| Sibling repo | `AnimMouse/dotfiles-codespaces` — container dotfiles, also current |
| GitHub credentials | [docs/GITHUB-APP.md](docs/GITHUB-APP.md): phases 1–3 **built and verified** — commit signing on the VM, a GitHub App token broker, and `GITHUB_AUTH=app` (no SSH credential in containers). Phase 4 (parity) and 5 (the VM itself on the app) are planned |
| Editor access | By client certificate, through nginx — [docs/EDITOR-MTLS.md](docs/EDITOR-MTLS.md). In daily use; the remaining Firefox checks are its §5 |

**Nothing in this repo is personal.** Your name, email and keys live on
`/persist`, never in git. `paths.nix` records the locations and no values.

### Built since the move

Each item is a module or launcher change with its own commit and a CLAUDE.md §8
row where something was learnt the hard way.

| What | Where | In short |
|---|---|---|
| VM control socket | `modules/vm-control.nix`, `scripts/vm{,-control}` | `vm status`, `vm build`, journals — read-only, for the flake's codespace |
| Editor access by client certificate | `modules/editor-proxy.nix`, `scripts/editor-tls` | nginx + mTLS + Fetch Metadata; editors on unix sockets with no password |
| `--config repo\|template\|plain\|<path>` | launcher, `templates/devcontainer.json` | which devcontainer.json; the template carries gh, Node, Claude Code on a volume |
| Shared code-server | launcher | unpacked once per version, immutable, mounted at `/mnt/code-server` |
| Dotfiles from the VM | launcher | `DOTFILES_REPOSITORY=/persist/dotfiles`, snapshotted per codespace |
| Faster creates | launcher | no `apt-get update` for `APT_MIRROR`; a plain create went from ~21 s to ~7 s |
| Commit signing on the VM | `modules/codespace-auth.nix`, `scripts/git-sign-*` | `GIT_SIGNING=vm`; the key never enters a container |
| GitHub App token broker | `scripts/github-app-login`, `scripts/github-token-service` | tokens scoped to the caller's repository, caller known by its container |
| `GITHUB_AUTH=app` | launcher, `scripts/git-credential-codespace`, `scripts/gh-codespace` | https with scoped tokens; `GITHUB_TOKEN` set, `GH_TOKEN` left for a PAT |
| Smaller fixes | launcher, `modules/persist.nix` | `rm --repo` refuses before removing anything; key login via `/persist/ssh` (0711); pre-nginx containers come up shell-only |

### Next

- **Phase 4 of the GitHub App plan**: `customizations.codespaces.repositories`,
  read-only tokens where you cannot write, revocation on `codespace rm`, `app`
  as the default, and CLAUDE.md §8/§9 amended away from agent forwarding.
- **Phase 5**: the VM itself on the app; the SSH key becomes signing-only.
- **The kiosk launcher** has never launched Firefox. Its profile check runs
  `firefox -P`, which may open Firefox's profile manager instead.
- **Phase 4 of the build order**: the OVA in CI, untouched.

---

## What the move actually changes

The Codespace could build and evaluate everything, but it could not *run* the
system. That asymmetry shaped how things were tested, and it disappears now.

### Things that were never tested, and now can be

These were built from documentation and inspection only:

- **Every systemd unit.** The Codespace had no systemd at all (PID 1 was
  `docker-init`). `code-server`, `code-server-password`, `codespace-proxy@`,
  `git-allowed-signers`, `git-identity-template`, `github-known-hosts` were all
  verified by reading the generated unit files, never by running them. All of
  them have now run clean on the VM — see below — but only on the happy path.
- **The Windows side:** `scripts/codespace-kiosk.ps1` parses under pwsh and its
  URL resolution is tested, but it has never launched Firefox.

If you touch any of these, you can now test them properly rather than by proxy.

### Verified on the VM

- **The hub editor** on port 8000, and `services.code-server` with it.
- **`ssh-auth` against the real user ssh-agent** (`services.ssh-agent` +
  lingering): the key loads, and containers see it through the forwarded socket.
- **`codespace rebuild dev-vm`**, observed from inside the result:
  - `${devcontainerId}` expands — `~/.claude` is the volume `claude-0rd4jj…`.
  - `~/.claude` is writable by `vscode`, and survives a second rebuild — the
    same volume, credentials intact.
  - `nil` installs.
  - `devcontainer-lock.json` was not rewritten; the hand-resolved digests stand.
  - Claude Code's npm prefix is `vscode`-owned, so self-update can write.
  - The image is Ubuntu 26.04; the editor comes up and `git commit` signs (`G`).
  - The agent socket is at `/mnt/git-ssh/agent.sock` and `ssh-add -l` lists
    the key — without docker-in-docker, which is the case the move was for.
- **The VM control socket**, from inside the dev-vm codespace: `/mnt/vm` holds
  a root-owned client and a 0600 socket; `vm status` names the running system
  and reads failed units; `vm journal code-server` answers and
  `code-server-password` is refused; `vm build` built in ~10s warm and reported
  no changes. The sandboxing broke nothing.
- **`codespace ls --size` against the real daemon**, through `vm codespaces`:
  IMAGE shows real per-container figures, so the daemon does compute
  `SharedSize`.
- **The tarball cache is reused.** Two rebuilds after the first download, the
  cached `code-server-4.143.1` tarball still carries its original mtime while
  the container's install is minutes old — the installer untarred it rather
  than fetching again.
- **`~/.claude.json` survives a rebuild** via `CLAUDE_CONFIG_DIR`: after
  `codespace rebuild dev-vm`, Claude Code started without the "configuration
  file not found" message, and the file is in `~/.claude`, not `$HOME`.
- **The systemd units, on the happy path** (`vm unit …`): `git-allowed-signers`,
  `git-identity-template` and `github-known-hosts` exit 0 at boot;
  `codespace-gc.timer` fires daily and the sweep logs "nothing idle past 60d";
  `code-server`, `docker` and `codespace-proxy@dev-vm` ran. No failed units.
  (`codespace-proxy@` has since been replaced by nginx.)
- **`rebuild` stops when nothing changed:** a second `rebuild` printed
  `no changes: already running …` and did not switch.
- **VM-side commit signing** (`GIT_SIGNING=vm`, phase 1 of
  [docs/GITHUB-APP.md](docs/GITHUB-APP.md)). A commit made in a codespace with
  the agent hidden was signed by the VM, logged against the container's ID,
  and shows Verified on GitHub. The dotfiles were changed to leave signing
  alone when the VM does it.
- **`GITHUB_AUTH=app`** (phase 3 of [docs/GITHUB-APP.md](docs/GITHUB-APP.md)),
  in the dev-vm codespace rebuilt with it: no agent socket, no `SSH_AUTH_SOCK`,
  no private key, and `ssh -T git@github.com` denied; `GITHUB_TOKEN` set and
  `GH_TOKEN` not; `gh api user` as the account through the shim, `gh pr list`
  working and another repo 403; a dry-run push accepted over https and
  another repo 403; commits signed on the VM.
- **The token broker** (phase 2 of [docs/GITHUB-APP.md](docs/GITHUB-APP.md)).
  From the dev-vm codespace, with nothing but the token able to authenticate:
  `/whoami` named the codespace and its container, the token is a `ghu_`
  acting as the account, a dry-run push to its own repo over https was
  accepted, and another private repo was refused with 403. It lives 8 hours.
- **Dotfiles from `/persist/dotfiles`.** A new codespace cloned its own
  snapshot (`origin` is `/mnt/dotfiles`, at the VM repo's committed HEAD) and
  ran `install.sh`; the whole dotfiles step took 67 ms against 3.5 s from
  GitHub. Its container layer was 440 KB, with code-server shared.
- **Shared code-server.** A new codespace links
  `/mnt/code-server/4.143.1/bin/code-server` from the VM's store, and root in
  the container gets `Permission denied` writing there; `lsattr` shows the
  store and the version immutable. The first run found `chattr -R` failing on
  symlinks, since replaced by `find ! -type l` (CLAUDE.md §8).
- **`--config template`** comes up with gh, Node, Claude Code and
  `CLAUDE_CONFIG_DIR` on the volume, and commits sign. Its features cost about
  a minute on the first build ever; after that every codespace on the same
  template hits the build cache — 33 s to create against 30 s for `plain`.
- **docker-in-docker on a 24.04 image**, in a throwaway codespace: the feature
  installed `iptables-legacy` as predicted, the launcher printed
  `switching to iptables-nft` and `dockerd is up`, and `docker run --rm
  hello-world` worked inside. The no-legacy-tables diagnosis is now observed,
  not just read from the kernel config.
- **The agent socket under docker-in-docker:** `SSH_AUTH_SOCK` is
  `/mnt/git-ssh/agent.sock` and `ssh-add -l` lists the key, despite the
  entrypoint's tmpfs over `/tmp`.
- **A generated config with a feature** comes up — after the `--no-lockfile`
  fix this test turned up (CLAUDE.md §8) — and nothing is written into the
  checkout: no `.devcontainer/` appeared.
- **`codespace rm <name> --volume`, then `--repo` later:** the dind volume was
  removed and reported by name, the checkout path was noted in
  `/persist/codespace/.removed/`, and the later `--repo` deleted exactly that
  checkout.

### Pending a real run

- **Editor access by client certificate** is cut over and working in Firefox;
  containers get `400` from every editor port and hold no editor credential.
  What is left to check — a fresh profile refused, webviews, cross-site pages,
  name constraints in Firefox — is [docs/EDITOR-MTLS.md](docs/EDITOR-MTLS.md)
  §5. Every codespace has been rebuilt onto it.

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

> The hub editor on `https://localhost:8000/` works too, behind the same
> certificate, since it runs on the VM and has Nix natively. Use whichever you prefer — the
> codespace keeps the tooling out of the VM, the hub avoids a second Nix store.

### The one thing the container cannot do

**Apply.** `nixos-rebuild switch` needs root on the VM and the VM's own store, so
the loop is:

```bash
# in the codespace terminal — edit, then verify
nix flake check
nix build .#nixosConfigurations.dev.config.system.build.toplevel --no-link
vm build        # the same build in the VM's store, diffed against what runs

# on the VM — apply what you just verified
rebuild
```

`vm` is the codespace's window onto the VM (`modules/vm-control.nix`): status,
allowlisted journals, `codespace list --size`, and builds. Read-only on
purpose. This codespace can write the checkout, so a socket that could also
switch would make it root on the VM. `vm help` lists the verbs.

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
  .removed/<name>                checkout path a plain `rm` left, for a later `rm --repo`
  secrets                        KEY=value, mode 0600
  code-server/<version>/         code-server, unpacked once and mounted into every
                                 container at /mnt/code-server. Immutable (chattr +i)
  <name>/                        port, generated devcontainer.json, secrets, last_used,
                                 dotfiles.git — its own snapshot of /persist/dotfiles
/persist/code-server/           hub editor extensions and state (a leftover `pw`
                                 is no longer read — delete it)
/persist/tls/                    editor CA, nginx's certificate, your browser's
                                 client.p12 + client.pass — root only
/run/editors/<port>/             each editor's unix socket; nginx picks by port
/persist/ssh/                    SSH *host* keys — the machine's identity —
                                 and authorized_keys.dev, read by sshd for key login
/persist/secrets/                spare 0700 dir, root-owned (sudo to use it)
/persist/docker/                 Docker data-root
/persist/home/dev/               the dev user's home
```

### `/persist/codespace/config`

| Key | Default | |
|---|---|---|
| `DOTFILES_REPOSITORY` | — | a URL, cloned inside the container; or a git repo on the VM such as `/persist/dotfiles`, snapshotted per codespace and mounted at `/mnt/dotfiles` |
| `DOTFILES_INSTALL_COMMAND` | — | usually `install.sh` |
| `DEFAULT_IMAGE` | `mcr.microsoft.com/devcontainers/base:ubuntu26.04` | for `--config plain` |
| `GIT_SSH_MODE` | `auto` | `auto` \| `agent` \| `keyfile` \| `none` |
| `GITHUB_AUTH` | `legacy` | `app`: no SSH credential in containers; git and `gh` use tokens scoped to the codespace's repository, signing on the VM (docs/GITHUB-APP.md). Takes effect on `codespace rebuild` |
| `GIT_SIGNING` | `agent` | `vm` signs commits on the VM (`modules/codespace-auth.nix`) instead of through the forwarded agent. Chosen on every `up` |
| `CONTAINER_GH_TOKEN` | `1` | set `GITHUB_TOKEN` in containers: the VM's `gh` token, or in `GITHUB_AUTH=app` a scoped one. `GH_TOKEN` is never set, so you can export your own over it |
| `CONTAINER_REFS` | `1` | mount `/persist/refs` |
| `APT_MIRROR` | — | rewrite apt sources in containers; no `apt-get update` — run it before your first install |
| `RETENTION_DAYS` | `30` | days idle before `codespace gc` removes the container; `0` disables |
| `CODE_SERVER_VERSION` | `latest` | pin the editor, e.g. `4.138.0`; a leading `v` is fine. Unpacked once into the shared store; takes effect on `codespace rebuild` |
| `VM_CONTROL` | the flake's codespace | names that get the VM control socket (below); empty for none. Takes effect on `codespace rebuild` |
| `TIMEZONE` | the VM's own | zone for every container, e.g. `Asia/Manila`. On `/persist` so it need not be committed — see below |

---

## Daily commands

```bash
rebuild --pull                  # git pull, then nixos-rebuild switch
rebuild [--force]               # stops at "no changes" unless forced
ssh-auth                        # unlock the git key into the agent, once per boot
github-app-login                # authorise the GitHub App, once (docs/GITHUB-APP.md)

codespace up <url|path|name>    # create/start a codespace and its editor
  [--config repo|template|plain|auto|<path>]   # which devcontainer.json; also on new, rebuild
codespace new <name>            # the same, on an empty workspace
codespace shell <name>          # a terminal inside it, in a tmux on the VM
codespace rebuild <name>        # recreate the container, keep the port
codespace down <name>           # stop it
codespace rm <name> [opts]      # --repo drops the checkout (also later), --volume its volumes (not later)
codespace list                  # + IDLE, the clock gc is counting
codespace list --size           # disk per codespace, and what is shared
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

- **Timezone lives in two places, and only one of them is committed.** The VM's
  is `time.timeZone` in `hosts/dev/configuration.nix`, currently `UTC`.
  Containers take `TIMEZONE` from the launcher config, falling back to the VM's
  own zone, so by default there is one answer rather than two that drift.
  Setting it on `/persist` alone keeps roughly-where-you-live out of a public
  repo while still giving every container the right clock; set both if you want
  the VM to match. Applied as `/etc/localtime` plus `TZ` in the container, and
  never fatal — an image with no tzdata just stays on UTC and says so.
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
- **`APT_MIRROR` cannot speed up devcontainer features, `postCreateCommand`
  or the dotfiles' `install.sh`** — features apt-install during the image
  build, and the other two run inside `devcontainer up`, all before the
  launcher rewrites the sources.
- **The container dotfiles are optional here** and load-bearing in real
  Codespaces. Do not fold them into this repo; that portability is the point.
- **`git config --global` does not work on the VM.** home-manager owns
  `~/.config/git/config` as a read-only store symlink. Use
  `git config -f /persist/git/identity …`.
- **The base image is pinned, so moving it is a choice.** `base:ubuntu26.04` in
  both the launcher default and this repo's own config — the bare `:ubuntu` tag
  moved to 26.04 under us once. The 26.04 tag has **no hyphen**; `ubuntu-26.04`
  is a 404. A codespace with an already-generated config keeps whatever image
  it names until you edit `/persist/codespace/<name>/devcontainer.json`.
- **docker-in-docker on 26.04 needs `"moby": false`.** The feature hard-refuses
  its default on `resolute`; `moby: false` installs Docker CE instead, and on
  26.04 the feature already picks nft, so the launcher's iptables fix does
  nothing there. That fix still matters for a project on a 24.04 image.
- **Claude Code's npm package lands root-owned.** Features install as root, so
  any project using the claude-code feature needs the second chown this repo's
  `postCreateCommand` carries, or auto-update fails with "no write permission
  to npm prefix".
- **Disk.** `codespace ls --size` first; README "Disk space" has the cleanup
  order and how to grow `persist.vdi`. Each container layer used to carry its
  own 676 MB copy of code-server; it is now shared from
  `/persist/codespace/code-server`. Each codespace sheds its copy on its next
  `codespace rebuild`, and `/persist/codespace/cache` can then be deleted.
- **Host RAM** is not returned by VirtualBox on its own. Save the machine state
  rather than shutting down; README "Host memory" has the balloon and sizing
  options.
- **Key login via `/persist/ssh/authorized_keys.dev` never worked** until
  `/persist/ssh` went from 0700 to 0711: sshd opens that file as `dev`, who
  could not enter the directory. Fixed and confirmed: sshd logs
  `Accepted publickey for dev` with an ED25519 key.
  Password login stays on deliberately. README setup step 2, BOOTSTRAP step 7.
