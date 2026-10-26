# Scoped GitHub credentials — phases 1–5 built and verified

Give each codespace a GitHub credential that reaches **only its own
repository**, the way a real Codespace's `GITHUB_TOKEN` does, using a personal
GitHub App that mints a scoped token per codespace — and sign its commits on
the VM, so no key that can authenticate ever reaches a container.

Built and verified on the VM: phase 1, signing on the VM
(`modules/codespace-auth.nix`, `scripts/git-sign-*`, `GIT_SIGNING`); phase 2,
the app, `github-app-login` and the token broker; phase 3, `GITHUB_AUTH=app` —
no SSH credential in containers, git and gh on scoped tokens, in use in every
codespace. Phase 4, parity with Codespaces, is built and checked on the VM
(§4.7), with two edges open. Phase 5, the VM itself on the app, is built
and checked (§6.1); the key stays an authentication key on GitHub while the
Windows host authenticates with it too. Facts marked *checked* were read from GitHub's
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

One SSH key, as CLAUDE.md §9 records, kept on the VM. Containers stop holding
it in any form — no agent, no key file — and get a scoped token for
authentication and a signing *service* for signatures. Since phase 5 the VM
only signs with it too (§6.1).

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

**Verify** — answered on the VM, from the dev-vm codespace, with the agent
unset and the https→ssh rewrites disabled so only the token could authenticate:
- [x] `/token/scoped` accepts HTTP basic auth with the client ID and **client
      secret**, as the broker sends it. Without the secret is untested.
- [x] A scoped token from a fresh account token lives **8 hours**; GitHub's
      `github-authentication-token-expiration` header agrees with the broker's
      cache. Still open: whether one scoped from an *older* account token gets
      only that token's remaining time. The broker uses GitHub's `expires_at`
      either way.
- [x] It is a `ghu_` user-to-server token acting as the account (`/user` says
      `type: User`, not a bot). `git push --dry-run` over https to its own
      repository is accepted; another of the account's repositories is
      refused with **403** by git and by the API. `gh` itself is not in that
      codespace; it is checked with the shim in phase 3.

---

## 4. Design

```
                     VM                                       container
 ┌─────────────────────────────────────────────┐      ┌───────────────────────────────┐
 │ /persist/github-app/                        │      │ git push ─► credential helper ┐│
 │   client_id, client_secret, refresh_token   │      │ gh ───────► shim ─────────────┤│
 │                │                            │      │                               ▼│
 │                ▼                            │ bind │ /mnt/github/token.sock         │
 │ token broker ──────────────► /run/codespace-auth/       ───►                       │
 │ ssh-agent ◄── signing service ──►           │ dir  │ /mnt/github/sign.sock          │
 │   (your one key; never leaves the VM)       │      │       ▲                        │
 └─────────────────────────────────────────────┘      │ git commit -S ─► sign client ──┘│
                                                       └───────────────────────────────┘
```

**One directory for every codespace**, `/run/codespace-auth/`, holding the
sockets, bind-mounted at `/mnt/github`. A directory, not the socket files: a
bind mount of a file pins its inode, so a restarted service would leave every
container holding a dead socket — learned with `vm-control` and the editor
sockets. Plumbing under `/mnt`, per CLAUDE.md §8.

**The kernel is the identity, not the socket.** The first version of this plan
gave each codespace its own directory and treated *that* as the identity —
which needs a socket unit per codespace, the kind nginx had just removed for
the editors. Instead the service asks the kernel who connected: `SO_PEERCRED`
gives the connecting process's PID as the VM sees it, and `/proc/<pid>/cgroup`
names its Docker container (`docker-<id>.scope`). Nothing inside a container
can forge either. Built that way for signing, where it only labels the log.

**Verify before tokens depend on it (phase 2):**
- [x] On the VM, the cgroup of a container's process names its container ID:
      the signing log showed `signed 1461 bytes for container 8d074aff3202`.
- [ ] A PID can be reused between `connect()` and reading its cgroup. For
      signing that only mislabels a log line; for tokens it must not happen —
      use `SO_PEERPIDFD` (kernel ≥ 6.5) and re-check the pidfd after reading.

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
| Repository permissions | Contents RW, Metadata R, Pull requests RW, Issues RW, Workflows RW, Actions RW, Checks R, Commit statuses R | the ceiling; each token asks for a subset |
| Install on | **All repositories** | new repos work without revisiting settings; scoping happens per token, not per install |

Workflows RW is in the ceiling because pushing a change under
`.github/workflows/` is refused without it, and Actions RW because
dispatching a workflow (`gh workflow run`), re-running or cancelling one is.
Both are granted per token only when asked for (§4.6).

**Changing the ceiling has an order.** GitHub refuses a scoped token that
asks for a permission the app lacks — the whole token, not that permission —
so add it to the app first, accept it on the installation (GitHub asks the
account to approve an app's new permissions), and only then rebuild a
launcher that asks for it. Checks and Commit statuses read, and Actions
raised to write, were added this way, after the first codespaces on the app
found CI unreadable and could not dispatch a workflow.

Only the client ID and client secret come out of this; both go to
`/persist/github-app/`, never into the repo — the same rule as the git identity
(CLAUDE.md §6).

### 4.2 One-time authorisation — `github-app-login` on the VM — built

`scripts/github-app-login`, in `modules/tools.nix`. Besides the steps below it
refuses a login that returns no refresh token (expiry turned off in the app),
checks the new token by asking `/user` and `/user/installations`, and passes
every token to curl on stdin, never on a command line.

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

### 4.3 The token broker — built, run against GitHub

`scripts/github-token-service`, `codespace-token.socket` in
`modules/codespace-auth.nix`, and `write_entitlement` in the launcher. Decided
here: **socket-activated handlers with a lock**, not one long-running process —
the same shape as signing, at `/run/codespace-auth/token.sock`, already inside
every container's `/mnt/github`. The caller is identified through
`SO_PEERPIDFD` (pidfd → PID → cgroup → container, then the pidfd re-checked),
which closes the PID-reuse race. Entitlements live in
`/run/codespace-auth-state/entitlements/<container-id>.json`, written by the
launcher at every `up` and dropped with the container. `GET /token` returns the
token as plain text; `GET /whoami` the entitlement and expiry, never the token.

*Tested* against a strict mock of GitHub, where each refresh token works once:
rotation persisted across four refreshes, cache hits made no calls, a scoped
token near expiry was re-scoped without a refresh, eight concurrent requests
with empty caches made exactly one refresh, and a lapsed refresh token
answered "run github-app-login". The real pidfd path refused a caller in no
container.

- Runs as `dev`, as a NixOS service (CLAUDE.md §10).
- Entitlement per codespace, written by the launcher at `up` to
  `/persist/codespace/<name>/github.json`:
  - the source repository, from the checkout's `origin` remote;
  - plus `customizations.codespaces.repositories`, read through
    `devcontainer read-configuration` so JSONC and `--override-config` are
    handled by the CLI rather than parsed by hand. *Checked* (CLI 0.87.0): its
    `.configuration.customizations` carries the block, comments and trailing
    commas handled, for a repo's own file and an override alike. §4.7.
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
- A codespace with no GitHub remote (`codespace new`) is answered "no
  repository" rather than refused, so the helper can say why.

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

*Checked* in a container, with the real handler: signing through the agent
and from an unencrypted key file, a 503 with "run ssh-auth" when neither can
sign, `git tag -s` (same invocation), a signature asked for directly verifying
only in namespace `git`, and `git log --show-signature` passing through to
`ssh-keygen`.

*Checked* on the VM: a commit made in a codespace with `SSH_AUTH_SOCK` unset —
so nothing in the container could sign — went through the client (`GIT_TRACE`
shows it run), was logged by the service against the container's ID, and
shows **Verified** on GitHub.

### 4.5 The rest of the container side — built

`scripts/git-credential-codespace` and `scripts/gh-codespace`, copied into
`/run/codespace-auth` and so present at `/mnt/github` in every container; the
launcher wires them in when `GITHUB_AUTH=app`. *Checked*: the github-cli
feature's real gh is found behind the shim by walking `PATH` and skipping the
shim itself (`-ef`, which dash supports), so its install path does not need
hard-coding. A container from before the switch keeps the SSH credential it
was created with — mounts are fixed — and `up` warns until it is rebuilt.

*Found while testing*: with no helper answering, git falls back to
`GIT_ASKPASS`, which code-server sets to its own prompt — so in an editor
terminal a broker failure shows as a password box, not an error. The helper
prints the broker's reason to stderr first.

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
- **gh**: reads its token once, at start, so a token in the environment goes
  stale after 8 hours. A shim at `/usr/local/bin/gh` — ahead of the feature's
  `/usr/bin/gh` on `PATH` — fetches a fresh token as `GITHUB_TOKEN` and `exec`s
  the real one. Real Codespaces has no shim, only the environment variable; a
  long-lived process here, such as a Claude Code session whose shell
  environment is captured at its start, would otherwise hold a dead token.
  **Verify** the github-cli feature's install path on both 24.04 and 26.04
  images.
- **`GITHUB_TOKEN` in `~/.codespace-secrets`**, filled from the broker at
  `up` instead of the VM's account-wide `gh auth token` — and renamed from
  `GH_TOKEN`, in both modes. `GITHUB_TOKEN` is what real Codespaces sets;
  `GH_TOKEN` outranks it in gh and is left to you, so `export GH_TOKEN=<a PAT>`
  lifts a codespace beyond its repository exactly as in a real Codespace. The
  credential helper honours `GH_TOKEN` too, so git and gh never disagree, and
  the shim does not ask the broker while it is set. Tools that read
  `GITHUB_TOKEN` once get a scoped token that may lapse after 8 hours. Every
  login shell fetches a fresh one from the broker over the saved one (written
  to `/etc/profile.d/codespace.sh` by the launcher; on failure the saved one
  stays), so a new terminal is always current; only a process already running
  past 8 hours holds an old one. git and gh are unaffected either way — the
  helper and the shim ask the broker per operation. `gh auth git-credential`
  as git's helper was considered and declined: one more hop to the same
  token, and git would then need gh installed, which a `plain` image lacks.
- **Removed from containers**: the forwarded agent, keyfile mode, the
  private key in every form, the https→ssh rewrite, and `GIT_SSH_COMMAND`.
  `/mnt/git-ssh` keeps the public key, identity, `allowed_signers` and
  `known_hosts`, which verification and the dotfiles use.

### 4.6 Permissions per token

Default for the source repository: Contents RW, Metadata R, Pull requests RW,
Issues RW, and read on Actions, Checks and Commit statuses — CI's results,
which `gh pr checks` and `gh run view` need and which a token without them
cannot see. Not changing CI: editing `.github/workflows/` needs Workflows
write and `gh workflow run` Actions write, and both start jobs with the
repository's secrets, so a codespace that does either says so — and `up` asks
you to approve it:

```jsonc
"customizations": {
  "codespaces": {
    "repositories": {
      "you/this-repo": { "permissions": { "workflows": "write", "actions": "write" } }
    }
  }
}
```

Read-only when you cannot write to the source repository, as in Codespaces.

**What each caller gets**, in one place. The launcher's `SOURCE_PERMISSIONS`
and `APP_PERMISSIONS` are the source of truth for the first two columns; the
app's settings (§4.1) for the last.

| Permission | A codespace, its own repository, by default | A codespace, by request and approval | The VM (§6.1) |
|---|---|---|---|
| Contents | write | write | write |
| Pull requests | write | write | write |
| Issues | write | write | write |
| Actions | read — `gh run list`, `gh run view` | **write** — `gh workflow run`, re-run, cancel | write |
| Checks | read — `gh pr checks` | read | read |
| Commit statuses | read | read | read |
| Workflows | — | **write** — push under `.github/workflows/` | write |
| Metadata | read | read | read |

| | A codespace | The VM |
|---|---|---|
| Repositories | its own; others of the same owner only through `customizations.codespaces.repositories`, approved at `up` | every repository the app is installed on — on a personal account set to *All repositories*, all of yours; an organisation's only where it installed the app |
| Narrowed by | the request, your approval, and read-only where you cannot push | nothing but the app's permissions |
| Token | scoped per permission set, 8 hours, revoked when the container goes | the account-wide user token, 8 hours, refreshed by the broker |
| Picks up a change to the app | at its next `up`, which rewrites its entitlement | at the broker's next refresh — no rebuild |

Every cell is also capped by your own access to each repository: where you
only read, the token only reads. Nothing in either column reaches what the app
lacks — repository administration (`gh repo create`, settings, deletion),
secrets and variables, Pages, packages, deploy keys, webhooks, or account
scope (SSH and GPG keys, emails, gists). Those answer 403 "Resource not
accessible by integration"; `GH_TOKEN=<a PAT> gh …` covers a one-off, and a
permission added to the app (§4.1, in its order) covers the rest.

### 4.7 Parity — phase 4, built

**Other repositories.** At `up`, the launcher reads
`customizations.codespaces.repositories` (`requested_repositories`) and
normalises it as Codespaces does: `read-all`, `write-all`, or a map of
permissions; `owner/*` for every repository of the owner. Then:

- **Same owner only**, as Codespaces requires — which also suits
  `/token/scoped`, whose `target` is one owner. Others are dropped with a note.
- **Clamped to the app's permissions** (§4.1, `APP_PERMISSIONS` in the
  launcher); GitHub refuses a token asking for more outright, so a request
  for, say, `secrets` is dropped with a note rather than breaking the token.
  `metadata: read` is always added.
- **The source repository's entry adds to its defaults** (§4.6), so naming it
  is how a codespace asks for `workflows`.
- **Approved on the VM** (`granted_repositories`). The container can write
  the `devcontainer.json` it came from, so honouring every request would let a
  compromised codespace widen its own token at the next `up`. Anything new or
  widened is shown and asked about; with no terminal it is left out and `up`
  says so. Approvals live in `/persist/codespace/<name>/repositories.approved`
  and are replaced by what was granted each time.

**One token per permission set.** A scoped token has one set of permissions
for all its repositories, so a union would give a repository asked for
read-only the write asked for another. The broker plans the entitlement into
groups by owner and permissions, one token each. The credential helper turns
on `credential.useHttpPath` and passes the repository as `/token?repo=`; the
broker returns the group covering it, a named entry before an `owner/*` one,
and refuses — naming the fix — a repository it has none for. A request with no
repository (`gh`, `GITHUB_TOKEN`) gets the source repository's group.

**Read-only where you cannot push.** When planning, the broker asks
`GET /repos/{owner}/{repo}` with the account token: `permissions.push` false
turns every permission of that repository to `read`; a 404 drops it, since
`/token/scoped` would refuse the whole group over it. A plan is reused until
the entitlement is rewritten (every `up`) or 8 hours pass, and a replan keeps
the tokens of groups that did not change. `owner/*` is not checked — GitHub
bounds a user token by your own access anyway.

**Revocation.** `POST /revoke?container=<id>`, accepted only from a caller in
no container — the VM. The launcher calls it whenever it drops an
entitlement: `rm`, `gc`, and the old container's on `rebuild`. The broker
`DELETE`s each live token at `/applications/{client_id}/token` and forgets
them; a replan revokes the tokens of groups that are gone too. Best effort: a
failure is logged and the container goes anyway, the token lapsing within 8
hours.

**`app` is the default.** Without `github-app-login` a codespace still comes
up, signs, and reads public repositories; `up` warns that nothing in it can
push. That is chosen over falling back to the SSH key silently.

*Tested* against a mock of GitHub (the broker's real functions, with GitHub
replaced): grouping, read-only on a repository without push, a 404 dropped,
`owner/*` without a repository list, named before wildcard, cache hits making
no calls, a replan keeping unchanged tokens and revoking a removed group's,
revocation of every live token, a container refused `/revoke` and the VM
refused `/token`. The launcher's normalising, approval and entitlement were
run with a stubbed CLI.

**Checked on the VM** (2026-10-26), in the dev-vm codespace and a throwaway
codespace for `dotfiles-codespaces` whose config asked for a named repository
`read-all`, `AnimMouse/*` with `contents: read`, another owner's repository,
and `administration` on its own:
- [x] git sends `path=owner/name` (no `.git`) with `useHttpPath`, on push and
      on `ls-remote`.
- [x] `up` dropped the other owner and `administration` with notes, asked
      before granting the rest, and the entitlement merged the source
      repository's request into its defaults.
- [x] One token per permission set: the source repository pushed, the
      `read-all` one cloned and was refused a push, and the broker answered
      403 for the other owner.
- [x] `/token/scoped` without `repositories` covers an unnamed private
      repository of the target (`git ls-remote` through `AnimMouse/*`).
- [x] Revocation: every token a container had fetched was revoked once — the
      replaced container's on `rebuild`, the last one's on `rm` — with
      success from GitHub. The log does not yet tell 204 from 404 for those
      runs; it does now.

**Still open:**
- [ ] A revoked scoped token is refused afterwards, and revoking one leaves
      the account token and the others working — the 204/404 split in the log
      answers the first half at the next `rm` or `rebuild`.
- [ ] git sends `path=` for LFS too.
- [ ] Read-only where you cannot push, against a real repository: all of a
      personal account's repositories are pushable, so this needs an
      organisation repository with read access. The planning's GitHub call
      itself is exercised on every `up` — `permissions.push` was read for each
      named repository above.
- [ ] `/token/scoped` with permissions you lack on a repository: refused or
      narrowed. Only an `owner/*` group can reach it now.

---

## 5. Consequences to accept or solve

- **The dotfiles turn signing off** unless changed. `git-signing-setup` in
  `dotfiles-codespaces` looks for an agent or a key file; with neither it takes
  its "no key found" branch and writes `gpgsign = false` to
  `~/.config/git/local` (*checked*, read in the script). That is user-level
  config, so it overrides the launcher's system-level `gpgsign = true`, and
  signing would silently stop. The script needs a first case: if the system
  config already sets `gpg.ssh.program` — the codespace signing service — leave
  signing alone. **Done** in `dotfiles-codespaces` alongside phase 1, and
  tested in all four cases: VM signing with and without the agent, the agent
  alone, and no key at all. It also adds the https→SSH rewrite only while an
  SSH credential is there to use it.
- **Private dotfiles repo.** `AnimMouse/dotfiles-codespaces` answers 404 to an
  anonymous API request, so it is private (*checked*). The dotfiles clone runs
  first in the container, before anything here exists (CLAUDE.md §8), and a
  token scoped to the project would not cover it anyway. **Resolved**: with
  `DOTFILES_REPOSITORY=/persist/dotfiles`, the launcher snapshots the repo on
  the VM and the container clones from a local mount — no network, no
  credential, so private needs nothing. The VM's own checkout pulls and pushes
  with the VM's full credentials.
- **Reference clones** in `/workspaces/refs` can no longer push. Public ones
  still clone (no credential is asked for). Clone and push those from the VM,
  which keeps its full credentials.
- **`codespace up <url>` clones on the VM**, with the VM's own credentials, as
  now. Only the container side changes.
- **Signing depends on the VM's agent holding the key**, as it does today with
  the forwarded agent — `ssh-auth` after a reboot, as now.
- **Revocation**: `codespace rm` drops the codespace's entitlement and
  revokes its cached tokens (`DELETE /applications/{client_id}/token`), as do
  `gc` and `rebuild` for the container they replace (§4.7). Scoped tokens
  expire on their own regardless.
- **Organisations must install the app.** A user access token reaches only
  where both you and the app can: acting *as* you is not acting *everywhere*
  you can. So an org's repositories need the app installed on that org — by
  an owner, or approved by one — after making the app public (app settings →
  Advanced). The existing authorisation then covers it; nothing to redo on the
  VM, and `/token/scoped` takes the org as its `target`. SAML-enforcing orgs
  may also need an active SSO session.
  - `gh auth login` and Git Credential Manager need no install because they are
    **OAuth Apps**: their tokens reach everything you can, in every org, and
    cannot be narrowed to one repository — the breadth this plan removes.
  - Real Codespaces needs none either: it is GitHub's own app, governed by the
    org's Codespaces settings instead of an installation — a privilege third-
    party apps do not get.
  - For an org that will not install it: `export GH_TOKEN=<a PAT>` in that
    codespace, and clone it on the VM with the PAT by hand (README).

---

## 6. Phases

Each phase ships on its own and leaves the system working.

1. **Signing service — built.** The VM-side service, the container client, and
   `gpg.ssh.program` in containers' system config, behind `GIT_SIGNING=vm`. The agent is still
   forwarded for authentication, so nothing can break that does not already
   work — this proves VM-side signing, "Verified" on GitHub included, before
   anything depends on it.
2. **App and broker on the VM.** Register the app (done), `github-app-login`
   (built, run), the broker (built). Checked by hand with `curl --unix-socket`: a scoped token pushes to
   its repo and is refused by another. Containers still untouched.
3. **Containers switch — the hole closes here. Built, behind
   `GITHUB_AUTH=app`, and verified in the dev-vm codespace**: no SSH credential
   in it, git and gh on the scoped token, other repositories refused. In one step: stop forwarding
   the agent and drop keyfile mode, add the credential helper and `gh` shim,
   fill `GH_TOKEN` from the broker, and flip the remote rewrite to https. (The
   dotfiles change already shipped with phase 1.) These cannot be split: taking the agent away before the
   token path exists leaves a container that cannot push. A launcher setting
   (`GITHUB_AUTH=app|legacy`, default `legacy` until this phase is proven) so
   one `codespace rebuild` moves a codespace either way.
4. **Parity — built and checked on the VM (§4.7), two edges open.**
   `customizations.codespaces.repositories`, read-only on repos you cannot
   write, revocation on `rm`. CLAUDE.md §8 (the agent-forwarding rows) and §9
   amended, the gotchas found added, and `app` the default.
5. **The VM itself on the app — built and checked.** Nothing on the VM
   authenticates with the SSH key; it only signs. Making it signing-only on
   GitHub waits on the Windows host having its own key. See §6.1.

### 6.1 Phase 5 — the VM authenticates with the app too

Today the VM pushes and pulls with the SSH key through the agent, and `gh` on
it uses an OAuth login that reaches everything. Phase 5 moves both onto the
app, leaving the key one job: signing.

**Design**

- **The broker answers the VM** (`scripts/github-token-service`). A caller
  gets the **account-wide** user token (§4.6 tabulates what it carries) —
  every repository the app is installed on — rather than a scoped one: the VM
  is trusted, and holds the refresh token anyway. It must be the broker, not a second client: two processes refreshing
  independently would rotate each other's refresh token out. *The VM* is two
  conditions, both read from the kernel: no Docker container in the caller's
  cgroup, **and** the broker's own PID namespace. The second was not in the
  plan; it costs one `readlink`, and refuses a process that left its
  container's cgroup — which takes a privileged container — but not its PID
  namespace. A caller passing neither test is refused, not treated as the VM.
  Containers still get only their scoped tokens.
- *Declined*: scoping the VM's git token to the repository of each operation.
  `gh` on the VM has no repository to name and needs the account-wide token
  anyway, so the VM would hold it regardless.
- **The VM's git config flips** (`home/dev.nix`): the https→SSH rewrite goes,
  SSH→https replaces it so checkouts with `git@github.com:` remotes keep
  working, and the helper the containers use asks the broker, with
  `CODESPACE_TOKEN_SOCK` pointing it at the socket's path on the VM. An empty
  helper entry first clears any other, and home-manager's
  `gh auth git-credential` helper is turned off.
- **gh on the VM** is the containers' shim too, wrapped as `programs.gh.package`
  around the real gh, so it gets a fresh token per run; `git_protocol` is
  `https`. A `gh auth login` OAuth session, if there is one, is removed by
  hand — the token from the environment outranks it, but it still reaches
  everything. (This VM never had one.)
- **`GITHUB_AUTH=legacy`** handed containers the VM's `gh auth token`; it now
  asks the broker for the account-wide token first. Its agent forwarding can
  no longer push once the key is signing-only.
- **On GitHub, the key becomes signing-only**: removed as an Authentication
  key, kept as a Signing key. That is what disables SSH auth — a leaked key
  could still sign, and could push nowhere. **Not done**: Git Bash on the
  Windows host authenticates with the same key, so removing its
  authentication role would lock Windows out. The VM no longer uses that role;
  it only stops existing once Windows has an authentication key of its own.

**Day to day**

| | Now | After |
|---|---|---|
| `git push`, `git pull`, `gh` on the VM | SSH key, through the agent | app token, fetched by the helper |
| After a reboot | `ssh-auth` before pushing | `ssh-auth` only before *signing*; pull and push work at once |
| `rebuild --pull` | SSH | https; the flake repository is public, so no credential at all |
| `codespace up github.com/…` | clones over SSH | clones over https with the app token |
| Every ~6 months unused | — | `github-app-login` again, if the refresh token lapsed |

**To accept or solve**

- Repositories under an account that has not installed the app become
  unreachable from the VM too — a PAT per command for those.
- The app's permissions become the ceiling everywhere: Contents, Pull
  requests, Issues, Workflows, Actions read, Metadata. Repository settings,
  deletion or secrets need a permission added. **Verify** whether creating a
  repository needs Administration write, before relying on `gh repo create`.
- A lapsed or revoked authorisation cuts the VM off from GitHub until
  `github-app-login`, which needs only a browser. A fresh install is
  unaffected: it clones the public flake anonymously.
- Signing still needs the agent unlocked, as now. Only authentication moves.

**Checks**

- [x] With the agent emptied (`ssh-add -D`): `gh api user`, `git push
      --dry-run` from `/persist/dev-vm`, and `git ls-remote` of a private
      repository all work from the VM; `gh auth status` names `GITHUB_TOKEN`,
      a `ghu_` token, and https for git. (2026-10-26)
- [x] Straight after, the dev-vm codespace still got its scoped token: the
      broker refused it that same private repository, naming its
      entitlement.
- [x] After `ssh-auth`, a commit made on the VM signs (`G`).
- [ ] `ssh -T git@github.com` from the VM is denied once the key is
      signing-only — waits on the Windows host's own key.
- [ ] `git push` and `gh pr list` on the VM work with no agent loaded.
- [ ] A container still cannot get the account-wide token.

### Rollback

`GITHUB_AUTH=legacy` plus `codespace rebuild` restores agent forwarding. The app can be uninstalled from GitHub at any time, which
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
- [ ] A repository added under `customizations.codespaces.repositories` is
      asked about at `up`, and once approved pushes — while one only granted
      `read-all` is refused a push, and one not listed is refused outright.
- [ ] A repository you can only read gets a read-only token even when asked
      for `write`.
- [ ] A codespace with no `DOTFILES_REPOSITORY` still commits as you and signs
      (CLAUDE.md §6); one *with* the dotfiles still signs too.
