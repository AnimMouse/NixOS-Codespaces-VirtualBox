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

And tell git who you are. `/persist/git/identity` is created for you on first
boot as an empty, commented template — you only have to fill it in:

```bash
git config -f /persist/git/identity user.name  "Your Name"
git config -f /persist/git/identity user.email you@example.com
```

**Not `git config --global`** — that fails with `could not lock config file`,
because home-manager owns `~/.config/git/config` as a read-only symlink into the
nix store. The template says so, since git's own error message advises exactly
the command that cannot work.

This is the only place your name and email are written down, and it is not in
this repo.

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

### If your key has a passphrase

Then it needs to be in the ssh-agent before any container can use it:

```bash
ssh-auth        # prompts once per boot; a no-op if already unlocked
```

**Why it is not optional.** Containers have no terminal to prompt at, so a
locked key simply cannot be used there — and ssh reports that as
`Permission denied (publickey)`, which looks exactly like a key that was never
registered on GitHub. `codespace up` detects the case and says so explicitly
rather than leaving you to guess.

A user ssh-agent runs as a systemd service, so its socket is
`/run/user/1000/ssh-agent` on every boot, and lingering keeps it alive when you
log out. That means the socket a container was created with is still the right
one at your next login. `AddKeysToAgent yes` is set, so the first `ssh` or `git`
of the boot adds the key after a single prompt.

In agent mode the container is handed the **socket**, plus the *public* key and
`known_hosts` as individual file mounts. The private key stays on the VM — which
makes this strictly safer than a passphrase-less key on disk, not just more
convenient.

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
| `codespace shell <name>` | A terminal inside it, from your SSH session |
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

## What persists inside a codespace

Only **`/workspaces/<name>`** is a bind mount of `/persist/repos/<name>`.
Everything else in the container is the container's own writable layer, and dies
with it.

| Inside the container | Backed by | Survives `codespace rebuild` / `rm` |
|---|---|---|
| `/workspaces/<name>` | `/persist/repos/<name>` | **yes** |
| `/workspaces/refs` | `/persist/refs` | **yes**, and shared with every codespace |
| `/workspaces/anything-else` | container layer | no |
| `$HOME`, `/tmp`, installed packages | container layer | no |

`/workspaces` itself is root-owned `755`, so a plain `cd .. && git clone` there
fails with `Permission denied` rather than quietly writing somewhere temporary —
which is the good outcome. With `sudo` it will succeed, and *that* is the trap:
the clone sits next to your real repo, looks identical, and is gone on the next
rebuild.

### Reference repos: `/workspaces/refs`

In real Codespaces `/workspaces` is itself persistent, so cloning a repo next to
your project for reference just works. Here only the project is a mount — so
`/persist/refs` is mounted at **`/workspaces/refs`** in every container to give
you the same shape:

```bash
cd /workspaces/refs && git clone https://github.com/someone/library
cd /workspaces/proj && ls ../refs/library      # sibling, exactly as before
```

It persists, and it is deliberately **shared across every codespace** — clone a
big reference repo once and they can all read it. That also means it is the
wrong place for anything project-specific or secret. `CONTAINER_REFS=0` in
`/persist/codespace/config` turns the mount off.

Because it is a real mount, `rebuild` and `rm` do not warn about it.

`refs` is a **reserved codespace name** — a codespace called that would mount its
own workspace over `/workspaces/refs` and hide every reference repo from itself.
`codespace up refs`, `codespace new refs` and a URL ending in `/refs` are all
refused with a suggested alternative. A repo genuinely named `refs` still works;
clone it under another name:

```bash
git clone https://github.com/someone/refs /persist/repos/refs-upstream
codespace up refs-upstream
```

### Secrets

The equivalent of Codespaces secrets. `KEY=value` lines, one per line, in
`/persist/codespace/secrets`:

```bash
install -m 600 /dev/null /persist/codespace/secrets
cat >> /persist/codespace/secrets <<'EOF'
NPM_TOKEN=npm_xxxxxxxx
API_TOKEN=some value with spaces
EOF
```

Per-codespace overrides go in `/persist/codespace/<name>/secrets` and win over
the global file. `codespace up` warns if either is readable by anyone but you.

They arrive in two places, because one is not enough:

- **At create time**, via the CLI's `--secrets-file`, so they reach
  `postCreateCommand` and the dotfiles `install.sh`. That is where a Codespaces
  secret like `$SSH_ANIMMOZ_KEY` is expected — so the same dotfiles work here.
- **In every shell afterwards**, from `~/.codespace-secrets` inside the
  container (mode `0600`, owned by the container user), sourced by
  `/etc/profile.d/codespace.sh`. The `--secrets-file` values do **not** persist
  past the commands that run during `up`, which is why both are needed.

The editor's terminals get them because code-server is started from a login
shell. Nothing is passed with `docker exec -e` and nothing secret is written
into the world-readable `profile.d`, so no value appears in a command line on
the VM.

Values are read at `up` time — edit the file, then `codespace up <name>` again.
Remove a secret and the next `up` clears it from the container.

> The file is parsed, never sourced, so a stray backtick in a value is just a
> character. Keep it to `KEY=value`; there is no quoting or interpolation.

### A faster apt mirror

Containers apt-install from `archive.ubuntu.com` by default, which may be a long
way from you. Point them somewhere nearer in `/persist/codespace/config`:

```bash
APT_MIRROR=http://mirror.rise.ph/ubuntu
```

`codespace up` rewrites `archive.ubuntu.com` and `security.ubuntu.com` (and
regional variants like `azure.archive.ubuntu.com`) to that host, in both the
deb822 `.sources` layout Ubuntu 24.04 uses and the older `.list` one, then runs
`apt-get update` once — apt caches package lists per URL, so without that the
next `apt install` just fails.

It only fires when the sources still point at Ubuntu's own hosts, so a repeat
`up` costs nothing. Unset it and nothing is touched.

> **It cannot speed up devcontainer features.** Those apt-install during the
> image *build*, before any container exists for this to run in. It speeds up
> everything after: your own installs, `postCreateCommand`, anything in a
> terminal.

Make sure the mirror carries `-security` as well as the release and `-updates`,
or you will silently stop getting security updates. `mirror.rise.ph` does.

### A second project

Make it a second codespace, rather than a second checkout in one:

```bash
codespace up github.com/you/other-project
codespace new scratch                       # or an empty one
```

Each gets its own container, port and editor. Use `refs` for things you only
want to *read*, and a codespace for things you want to work in.

`codespace rebuild` and `codespace rm` now list anything under `/workspaces`
that is not the mount before they discard the container, so you get a chance to
notice.

> `$HOME` not persisting is normal for dev containers and is why dotfiles are
> reinstalled on every create. Put anything you want to keep in the workspace.

## A terminal without the browser

`codespace shell <name>` opens a shell inside the container, from the SSH
session you are already in — no second browser tab, and no second SSH port:

```bash
ssh -p 2222 dev@localhost        # from Windows Terminal
codespace shell project          # you are now inside the container
```

It lands as the container's own user, in the workspace folder, with the same
git identity, `GH_TOKEN` and SSH access the editor's terminals get.

**It runs inside a tmux session on the VM** (`cs-<name>`), so dropping your SSH
connection does not kill what you were running — reconnect and
`codespace shell project` puts you back in the same shell. tmux is on the VM
rather than in the container on purpose: no image has to ship it, and the
session survives the container being restarted under it.

```bash
codespace shell project -- npm test    # one-shot, no tmux, pipeable
codespace shell project --no-tmux      # plain interactive shell
```

Already inside tmux? It will not nest — you get a plain shell.

> **Why not SSH straight into the container?** It would mean an sshd and
> authorised keys in every image, plus another forwarded port per codespace, to
> reach something `docker exec` already reaches through the SSH session you are
> sitting in. The editor ports are for editors; terminals come through here.

## Rebuilding the VM

After changing anything in this repo:

```bash
rebuild --pull          # git pull /persist/dev-vm, then switch
rebuild                 # switch without pulling
rebuild --rollback      # anything else goes straight to nixos-rebuild
```

From Windows, without logging in:

```powershell
ssh -p 2222 dev@localhost 'sudo nixos-rebuild switch --flake /persist/dev-vm#dev'
```

Passwordless sudo for `wheel` exists precisely so that non-interactive form
works: `ssh host 'sudo ...'` gets no TTY and cannot answer a prompt.

To roll back a bad rebuild: `sudo nixos-rebuild switch --rollback`, or pick an
older generation from the GRUB menu.

## Your git identity

`/persist/git/identity` is a gitconfig fragment, and the single place your name
and email live. A first boot seeds it as comments only:

```bash
git config -f /persist/git/identity user.name  "Your Name"
git config -f /persist/git/identity user.email you@example.com
```

The template carries no placeholder values on purpose. git ignores a
comments-only include, so an unedited VM has *no* identity and asks who you are
on the first commit — which is much better than quietly authoring everything as
"Your Name".

The VM's git config `include`s it, and `codespace up` mounts it into every
container *and* adds the include to the container's system git config — so it
works whether or not you use a dotfiles repo. The VM and its containers author
commits as the same person, from one file. It also feeds `allowed_signers`, which needs the committer address to
verify your own signatures.

It is deliberately **not** in this repo. A personal identity in a public flake
is both a privacy leak and a thing that silently disagrees with your dotfiles;
keeping it on `/persist` means one file to edit and nothing to keep in sync.
`paths.nix` at the repo root says where it lives, and holds no values.

A missing include is silently ignored by git, so a VM without one has no
identity and says so on the first commit — rather than authoring as someone
else.

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

**How containers get credentials** — checked in this order, and what each mode
actually exposes under `/mnt/git-ssh`:

| | Used when | Container gets | Private key exposed? |
|---|---|---|---|
| **ssh-agent** | the agent holds a key | the socket at `/tmp/ssh-agent.sock`, plus `id_ed25519.pub` and `known_hosts` as single-file mounts | **No** |
| **key file** | no agent, and the key has no passphrase | the whole `/persist/git` directory, and `GIT_SSH_COMMAND` pointing at the key | Yes — it is the only way this mode can work |
| **neither** | the key is passphrase-locked and no agent holds it | `id_ed25519.pub` and `known_hosts` only; a loud warning naming the `ssh-add` to run | No |

The mode is chosen automatically, but you can pin it in
`/persist/codespace/config`:

```bash
GIT_SSH_MODE=agent      # auto (default) | agent | keyfile | none
```

**`agent` is the one to set** if you care. The default `auto` is convenient but
it downgrades silently — forget to `ssh-add` once and it mounts the private key
into the container instead, which is precisely what you were avoiding.
`GIT_SSH_MODE=agent` turns that into a hard error naming the `ssh-add` to run.
It is also the only mode that can work at all with a passphrase-protected key.

The public half is mounted in every mode because the container needs it to
configure commit signing — `user.signingkey` is the `.pub`, and `ssh-keygen -Y
sign` falls back to the agent when the private half is unreadable.

With the agent, `git clone`, `git push` and commit signing inside the container
all work with **no passphrase prompt** — the crypto happens back on the VM.
Signing works because `user.signingkey` is the *public* key, and `ssh-keygen -Y
sign` will use the agent when the private half is unreadable.

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
Codespaces uses, so one repo works in both places.

**Nothing here depends on it.** The launcher writes the whole git story into the
container's *system* config: identity, signing, `allowed_signers`, and the
https→ssh rewrite. A codespace with no dotfiles at all still commits as you and
still signs. The dotfiles set the same things at the global level, which is a
harmless duplicate.

| | Set by |
|---|---|
| name and email | launcher (and dotfiles) |
| `gpg.format`, `user.signingkey`, `commit.gpgsign` | launcher (and dotfiles) |
| `allowed_signers`, `url.insteadOf` | launcher (and dotfiles) |
| `GIT_SSH_COMMAND`, `SSH_AUTH_SOCK`, `GH_TOKEN` | launcher only |
| shell, aliases, editor preferences | dotfiles only |
| key material in **real Codespaces** (`$SSH_ANIMMOZ_KEY`) | dotfiles only |

So the dotfiles are now your *portable preferences* layer, not the thing that
makes git work here. They still do the whole job in real Codespaces, where
there is no launcher. It finds its signing key in
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
/persist/refs/           reference checkouts, shared read/write with all containers
/persist/git/            the SSH key, your identity, allowed_signers, known_hosts
/persist/ssh/            SSH host keys — machine identity, not yours
/persist/home/dev/       the dev user's home (/home/dev symlinks here)
/persist/docker/         images, volumes, containers
/persist/codespace/      per-codespace port + config, launcher config, secrets
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
  tools.nix                     the `rebuild` and `ssh-auth` commands
paths.nix                       where identity and key material live (paths only)
scripts/codespace               the launcher
scripts/rebuild                 rebuild [--pull]
scripts/ssh-auth                unlock the git key into the agent
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
| Editor URL will not load | `codespace up` now says which half is broken. Otherwise: `codespace logs <name>` for the editor, `systemctl status codespace-proxy@<name>` for the proxy |
| After a VM reboot, `codespace up` says the editor is not answering and `codespace logs` shows nothing newer than the shutdown | The editor is not being restarted. Fixed — `up` now probes the editor over HTTP instead of looking for its process, so a container that was stopped with the VM gets its editor started again |
| `editor did not answer on port NNNN`, but `codespace logs` shows a healthy editor | The proxy, not the editor. A unit that failed repeatedly used to hit systemd's start rate limit and then refuse `restart` outright. Fixed by disabling the limit and calling `reset-failed`; to clear an already-wedged one: `sudo systemctl reset-failed codespace-proxy@<name>` |
| Terminal opens in `$HOME`, `git status` fails | Editor started without a folder. `codespace up <name>` replaces it |
| Dotfiles not applied, no error | The clone failed silently. Check the repo is reachable and the key is registered |
| Commits are not signed | `cat ~/.config/git/local` in the container — no key found. `codespace rebuild <name>` |
| `codespace up` hangs at `Executing command ./install.sh...` | Something in the dotfiles install is waiting for input. The usual culprit is `ssh-keygen` on a passphrase-protected key: the tooling gives install.sh a tty, so it prompts and waits forever, and the prompt is usually swallowed. Ctrl-C, then `codespace rebuild <name>`. Keep every `ssh-keygen` in a dotfiles repo non-interactive with `-P ""` |
| `git@github.com: Permission denied (publickey)` inside a container | Either the key is passphrase-locked with no agent holding it — `ssh-auth`, then `codespace rebuild <name>` — or it is not registered on GitHub as an *Authentication* key. The two produce an identical message; `ssh -T git@github.com` on the VM tells them apart |
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
