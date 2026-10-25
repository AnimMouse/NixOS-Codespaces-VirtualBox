# Scoped GitHub credentials — plan, not built

Give each codespace a GitHub credential that reaches **only its own
repository**, the way a real Codespace's `GITHUB_TOKEN` does, using a personal
GitHub App that mints a scoped token per codespace — and sign its commits on
the VM, so no key that can authenticate ever reaches a container.

Nothing here is implemented yet. Facts marked *checked* were read from GitHub's
documentation, from source, or observed; facts marked **verify** must be
confirmed before or during the build, and the design bends if they turn out
false.

---

## 1. Why

Today every container can act as the whole account:

| Credential | How it gets in | What it reaches |
|---|---|---|
| `GH_TOKEN` | the VM's `gh auth token`, written to `~/.codespace-secrets` | the API for every repository the account can reach |
| The SSH key | the forwarded agent at `/mnt/git-ssh/agent.sock`, or the key file in keyfile mode | `git push` to every repository the account can push to |

A dependency's install script, a compromised extension or a careless agent in
*any* codespace can push to *every* repository. Real Codespaces does not work
this way: a codespace's token is scoped to its source repository, and anything
more is requested in `devcontainer.json` and approved by the user.

A scoped token alone does not fix this. **An ssh-agent has no notion of
"signing only"**: signing a commit and authenticating to GitHub are the same
operation to it — sign what you are given — so whatever can reach the forwarded
agent can `git push git@github.com:you/anything`. The agent has to stop
reaching containers, and signing has to happen somewhere else.

### What stays

One SSH key, as CLAUDE.md §9 records: it still authenticates and signs, on the
VM. Containers stop holding it in any form — no agent, no key file — and get a
scoped token for authentication and a signing *service* for signatures.

---

## 2. How real Codespaces does it — the target

*Checked* (GitHub Codespaces security reference):

- The token is scoped read/write to the source repository if you can write to
  it, read-only otherwise.
- Other repositories are added only through `devcontainer.json`, and the user
  approves them:
  ```jsonc
  "customizations": {
    "codespaces": {
      "repositories": {
        "you/other-repo": { "permissions": { "contents": "write" } },
        "you/lib":        { "permissions": "read-all" }
      }
    }
  }
  ```
- Git goes over HTTPS with that token. There is no SSH key in the codespace.

Honouring that same `customizations.codespaces.repositories` block here keeps
`devcontainer.json` portable in both directions (CLAUDE.md §1).

---

## 3. Why a GitHub App, and which token

| Option | Acts as | Scoped per repo | Created by | Verdict |
|---|---|---|---|---|
| Fine-grained PAT per repo | you | yes | **hand, in the web UI** — there is no creation API; a pre-fill link can set name, permissions and expiry but not the repository (*checked*) | Workable stopgap; manual per new repo |
| App **installation** token | `yourapp[bot]` | yes, `repositories` / `repository_ids` | API, JWT | **No** — 1-hour lifetime, and pushes and PRs show the bot, not you (*checked*) |
| App **user access** token, scoped down | **you** | yes | API | **Chosen** |

User access tokens (*checked*, GitHub Apps docs):

- Carry only permissions both you and the app have, on repositories both can
  reach.
- Expire after **8 hours**; the refresh token after **6 months**. Expiry can be
  turned off in the app settings — this plan keeps it on.
- Using a refresh token returns a **new** refresh token and invalidates the old
  one and its access token. The broker must persist the new one atomically
  before using the new access token.
- When the token came from the **device flow**, refreshing needs no client
  secret.
- `POST /applications/{client_id}/token/scoped` takes the account-wide user
  token plus `target`, `repositories` or `repository_ids`, and `permissions`, and
  returns a token limited to them.

**Verify:**
- [ ] How `/token/scoped` authenticates. The docs body does not say; the sibling
      `/applications/{client_id}/token` endpoints use HTTP basic auth with the
      client ID and **client secret**. Plan for needing the secret.
- [ ] The scoped token's lifetime — whether it inherits the parent's remaining
      8 hours, or gets its own.
- [ ] That a scoped token works for `git push` over HTTPS and for `gh` (PRs,
      issues) on that repository, and gets 403/404 on every other.

---

## 4. Design

```
                     VM                                       container
 ┌─────────────────────────────────────────────┐      ┌───────────────────────────────┐
 │ /persist/github-app/                        │      │ git push ─► credential helper ┐│
 │   client_id, client_secret, refresh_token   │      │ gh ───────► shim ─────────────┤│
 │                │                            │      │                               ▼│
 │                ▼                            │ bind │ /mnt/github/token.sock         │
 │ token broker ──────────────► /run/codespace-auth/<name>/ ───►                       │
 │ ssh-agent ◄── signing service ──►           │ dir  │ /mnt/github/sign.sock          │
 │   (your one key; never leaves the VM)       │      │       ▲                        │
 └─────────────────────────────────────────────┘      │ git commit -S ─► sign client ──┘│
                                                       └───────────────────────────────┘
```

Each codespace gets **one directory**, `/run/codespace-auth/<name>/`, holding
its two sockets, bind-mounted at `/mnt/github`. A directory, not the socket
files: a bind mount of a file pins its inode, so a restarted service would
leave every container holding a dead socket — learned with `vm-control` and the
editor sockets. Plumbing under `/mnt`, per CLAUDE.md §8.

**The directory is the identity.** A request arriving on `wgcf-connector`'s
sockets can only ever get what `wgcf-connector` is entitled to; nothing in the
request can widen it. The same per-codespace identity makes revocation on
`codespace rm` and a per-codespace signing log possible.

### 4.1 The app — by hand, in the GitHub web UI

Like the VirtualBox setup, this is GUI work you do; the repo documents it and
does not script it.

| Setting | Value | Why |
|---|---|---|
| Owner | your account | personal |
| Where can it be installed | Only on this account | nobody else needs it |
| Webhook | **Inactive** | nothing listens |
| Device flow | **Enabled** | the VM is headless; GitHub refuses the flow otherwise (*checked*) |
| Expire user authorization tokens | **On** (the default) | a leaked token dies in hours |
| Repository permissions | Contents RW, Metadata R, Pull requests RW, Issues RW, Workflows RW, Actions R | the ceiling; each token asks for a subset |
| Install on | **All repositories** | new repos work without revisiting settings; scoping happens per token, not per install |

Workflows RW is in the ceiling because pushing a change under
`.github/workflows/` is refused without it. It is granted per token only when
asked for (§4.6).

Only the client ID and client secret come out of this; both go to
`/persist/github-app/`, never into the repo — the same rule as the git identity
(CLAUDE.md §6).

### 4.2 One-time authorisation — `github-app-login` on the VM

A new command next to `ssh-auth` in `modules/tools.nix`:

1. `POST https://github.com/login/device/code` with the client ID.
2. Print the user code and `https://github.com/login/device`; you enter it in
   Firefox on Windows.
3. Poll `POST https://github.com/login/oauth/access_token` until authorised.
4. Write the refresh token to `/persist/github-app/refresh_token` (`0600`,
   owned by `dev`). The access token is not stored — the broker refreshes on
   first use.

It runs again only if the refresh token lapses: unused for 6 months, or
revoked. The broker says so by name rather than failing opaquely, the way the
launcher names the `ssh-add` to run for a locked key (CLAUDE.md §8).

### 4.3 The token broker

- Runs as `dev`, as a NixOS service (CLAUDE.md §10).
- Entitlement per codespace, written by the launcher at `up` to
  `/persist/codespace/<name>/github.json`:
  - the source repository, from the checkout's `origin` remote;
  - plus `customizations.codespaces.repositories`, read through
    `devcontainer read-configuration` so JSONC and `--override-config` are
    handled by the CLI rather than parsed by hand. **Verify** that its output
    includes `customizations`.
- On request: refresh the account-wide user token if it is near expiry,
  persist the rotated refresh token, call `/token/scoped`, cache the result
  until a few minutes before it expires, return it.
- **Refreshes must be serialised**: each one invalidates the previous refresh
  token (§3), so two at once would lock the VM out until `github-app-login`
  runs again. Either one long-running process, or socket-activated handlers in
  the `vm-control` style with a `flock` around the refresh. Decide in phase 2;
  the per-codespace sockets lean towards one process that listens on all of
  them, since a socket unit per codespace would bring back the per-codespace
  units nginx just removed.
- A codespace with no GitHub remote (`codespace new`) gets a socket that
  answers "no repository" rather than no socket, so the helper can say why.

### 4.4 The signing service — your key, used on the VM only

*Checked* (git 2.56, by logging a stand-in program): with `gpg.format=ssh`, git
signs by running

```
<gpg.ssh.program> -Y sign -n git -f <public key file> <buffer file>
```

with the commit or tag in the buffer file, nothing on stdin, and the signature
expected in `<buffer file>.sig`. Verification (`git log --show-signature`)
calls the same program with other `-Y` modes that need no private key.

So:

- **In the container**, the launcher sets `gpg.ssh.program` in the *system*
  git config to a small client, `/usr/local/bin/git-sign-codespace`. On
  `-Y sign` it sends the buffer to `/mnt/github/sign.sock` and writes the
  returned signature to `<buffer file>.sig`. Any other mode it hands to the
  real `ssh-keygen`, so verification keeps working locally.
- **On the VM**, the service runs `ssh-keygen -Y sign -n git` against the agent
  holding your existing key, and returns only the signature. It **always** uses
  namespace `git` and always your key, whatever the client asks for: the
  client's `-n` and `-f` are ignored.
- **Why this is safe where forwarding the agent is not**: an `-n git`
  signature is an SSHSIG over a namespaced blob — a different format from an
  SSH authentication signature, and unusable to log in. A compromised codespace
  can get commits signed as you; it cannot authenticate as you or push
  anywhere but its own repository through its scoped token. A separate
  signing-only key in the container would allow exactly the same signing.
- **Locked key**: if the VM's agent holds no key (after a reboot, before
  `ssh-auth`), the service answers with that, and the client prints "run
  ssh-auth on the VM" instead of git's opaque signing failure.
- Each signature is logged with the codespace's name, the commit's first line,
  and its size.
- Nothing changes on GitHub: same key, same registrations, commits stay
  "Verified".

**Verify:**
- [ ] Tag signing (`git tag -s`) uses the same invocation.
- [ ] A signature made this way verifies as "Verified" on GitHub, as one made
      with the forwarded agent does today.

### 4.5 The rest of the container side

- **git**: a credential helper, `/usr/local/bin/git-credential-codespace`, set
  in the *system* git config as `credential.https://github.com.helper`, for the
  same reason identity and signing are written there today (CLAUDE.md §6). It
  asks the socket with `curl --unix-socket`, which the devcontainers base images
  ship.
- **SSH remotes**: a checkout is shared between the VM and its container, so
  one cloned as `git@github.com:…` has that URL in the container too, where no
  SSH key exists any more. The system git config gets
  `url."https://github.com/".insteadOf` for both `git@github.com:` and
  `ssh://git@github.com/`, replacing today's rewrite in the other direction.
  The VM and the checkout's own `.git/config` are untouched.
- **gh**: reads `GH_TOKEN` once, at start, so a token in the environment goes
  stale after 8 hours. A shim at `/usr/local/bin/gh` — ahead of the feature's
  `/usr/bin/gh` on `PATH` — fetches a fresh token and `exec`s the real one.
  **Verify** the github-cli feature's install path on both 24.04 and 26.04
  images.
- **`GH_TOKEN` in `~/.codespace-secrets`**: kept, but filled from the broker at
  `up` instead of the VM's account-wide `gh auth token`. Tools that read the
  variable once get a scoped token that may lapse; that is a strict improvement
  on an account-wide one that does not.
- **Removed from containers**: the forwarded agent, keyfile mode, the
  private key in every form, the https→ssh rewrite, and `GIT_SSH_COMMAND`.
  `/mnt/git-ssh` keeps the public key, identity, `allowed_signers` and
  `known_hosts`, which verification and the dotfiles use.

### 4.6 Permissions per token

Default for the source repository: Contents RW, Metadata R, Pull requests RW,
Issues RW. Not Workflows — a codespace that edits CI says so:

```jsonc
"customizations": {
  "codespaces": {
    "repositories": {
      "you/this-repo": { "permissions": { "contents": "write", "workflows": "write" } }
    }
  }
}
```

Read-only when you cannot write to the source repository, as in Codespaces.

---

## 5. Consequences to accept or solve

- **The dotfiles turn signing off** unless changed. `git-signing-setup` in
  `dotfiles-codespaces` looks for an agent or a key file; with neither it takes
  its "no key found" branch and writes `gpgsign = false` to
  `~/.config/git/local` (*checked*, read in the script). That is user-level
  config, so it overrides the launcher's system-level `gpgsign = true`, and
  signing would silently stop. The script needs a first case: if the system
  config already sets `gpg.ssh.program` — the codespace signing service — leave
  signing alone. It changes in phase 3, with the launcher.
- **Private dotfiles repo.** `AnimMouse/dotfiles-codespaces` answers 404 to an
  anonymous API request, so it is private (*checked*). The dotfiles clone runs
  first in the container, before anything here exists (CLAUDE.md §8), and a
  token scoped to the project would not cover it anyway. Options, to decide
  before phase 3:
  1. make it public — it holds no values by design (§6);
  2. the launcher passes a one-shot token scoped to the dotfiles repo with
     Contents read, via `--secrets-file` and a `--remote-env` credential
     helper.
- **Reference clones** in `/workspaces/refs` can no longer push. Public ones
  still clone (no credential is asked for). Clone and push those from the VM,
  which keeps its full credentials.
- **`codespace up <url>` clones on the VM**, with the VM's own credentials, as
  now. Only the container side changes.
- **Signing depends on the VM's agent holding the key**, as it does today with
  the forwarded agent — `ssh-auth` after a reboot, as now.
- **Revocation**: `codespace rm` removes the codespace's socket directory and
  revokes its cached token (`DELETE /applications/{client_id}/token`). Scoped
  tokens expire on their own regardless.

---

## 6. Phases

Each phase ships on its own and leaves the system working.

1. **Signing service.** The VM-side service, the container client, and
   `gpg.ssh.program` in containers' system config. The agent is still
   forwarded for authentication, so nothing can break that does not already
   work — this proves VM-side signing, "Verified" on GitHub included, before
   anything depends on it.
2. **App and broker on the VM.** Register the app, `github-app-login`, the
   broker. Checked by hand with `curl --unix-socket`: a scoped token pushes to
   its repo and is refused by another. Containers still untouched.
3. **Containers switch — the hole closes here.** In one step: stop forwarding
   the agent and drop keyfile mode, add the credential helper and `gh` shim,
   fill `GH_TOKEN` from the broker, flip the remote rewrite to https, and ship
   the dotfiles change. These cannot be split: taking the agent away before the
   token path exists leaves a container that cannot push. A launcher setting
   (`GITHUB_AUTH=app|legacy`, default `legacy` until this phase is proven) so
   one `codespace rebuild` moves a codespace either way.
4. **Parity.** `customizations.codespaces.repositories`, read-only on repos you
   cannot write, revocation on `rm`. Amend CLAUDE.md §8 (the agent-forwarding
   rows) and §9, add the gotchas found, and make `app` the default.

### Rollback

Through phase 3, `GITHUB_AUTH=legacy` plus `codespace rebuild` restores today's
behaviour. The app can be uninstalled from GitHub at any time, which
invalidates every token it ever issued.

---

## 7. Checks before calling it done

- [ ] Every **verify** item above, answered and recorded in CLAUDE.md §8.
- [ ] In a codespace for repo A: `git push` to A works; `git push` to B fails;
      `gh pr create` on A shows **you** as author, not a bot.
- [ ] `ssh -T git@github.com` from a container fails, and
      `ls /mnt/git-ssh/agent.sock` finds nothing: no key can authenticate.
- [ ] A commit made in a container shows "Verified" on GitHub, signed by your
      existing key.
- [ ] A checkout with an SSH `origin` pushes from its container over HTTPS.
- [ ] A codespace left running past 8 hours still pushes.
- [ ] After `codespace rm`, its cached token no longer works.
- [ ] A codespace with no `DOTFILES_REPOSITORY` still commits as you and signs
      (CLAUDE.md §6); one *with* the dotfiles still signs too.
