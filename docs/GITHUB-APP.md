# Scoped GitHub credentials — plan, not built

Give each codespace a GitHub credential that reaches **only its own
repository**, the way a real Codespace's `GITHUB_TOKEN` does, using a personal
GitHub App that mints a scoped token per codespace.

Nothing here is implemented yet. Facts marked *checked* were read from GitHub's
documentation or observed; facts marked **verify** must be confirmed before or
during the build, and the design bends if they turn out false.

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

A scoped token alone does not fix this — the forwarded SSH key would still push
anywhere. Both have to change.

### This amends a recorded decision

CLAUDE.md §9 says: *"One SSH key does authentication and signing. No PAT."*
This plan keeps the first half on the VM and reverses it in containers: the VM
keeps its SSH key for everything; containers get **no authentication key at
all**, a separate **signing-only** key, and an app-minted token. §9 gets
amended when this lands, not before.

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
                    VM                                    container
 ┌────────────────────────────────────────┐      ┌──────────────────────────────┐
 │ /persist/github-app/                   │      │                              │
 │   client_id, client_secret  (0600)     │      │ git ──► credential helper ─┐ │
 │   refresh_token             (0600)     │      │ gh  ──► shim ──────────────┤ │
 │            │                           │      │                            ▼ │
 │            ▼                           │ bind │  /mnt/github/token.sock      │
 │ codespace-tokens.service ──► per-codespace ───►  (HTTP over a unix socket)   │
 │   one process, serialised refresh      │ sock │                              │
 │   scoped token cached until near expiry│      │ ssh-keygen -Y sign ─┐        │
 │                                        │      │                     ▼        │
 │ ssh-agent (signing key only) ──────────────────►  /mnt/git-ssh/agent.sock    │
 └────────────────────────────────────────┘      └──────────────────────────────┘
```

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
asked for (§4.5).

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

### 4.3 The broker — `codespace-tokens.service`

**One** service, not a template per codespace: refresh tokens rotate on use
(§3), so two processes refreshing at once would invalidate each other. One
process serialises that for free.

- Runs as `dev`, from `modules/codespace.nix`, as a plain NixOS service
  (CLAUDE.md §10). Python from nixpkgs: it is JSON and HTTPS, which shell does
  badly.
- Listens on one unix socket per codespace under
  `/run/codespace-tokens/<name>.sock`. **The socket is the identity**: a request
  on `wgcf-connector.sock` can only ever get a token for what `wgcf-connector`
  is entitled to. Nothing in the request can widen it.
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
- A codespace with no GitHub remote (`codespace new`) gets a socket that
  answers "no repository" rather than no socket, so the helper can say why.

### 4.4 The container side

All plumbing under `/mnt`, per the rule recorded with the agent-socket move
(CLAUDE.md §8).

- **Socket**: bind-mounted at `/mnt/github/token.sock`.
- **git**: a credential helper written by the launcher into the container
  (`/usr/local/bin/git-credential-codespace`) and set in the *system* git config
  as `credential.https://github.com.helper`, for the same reason identity and
  signing are written there today (CLAUDE.md §6). It asks the socket with
  `curl --unix-socket`, which the devcontainers base images ship.
- **gh**: reads `GH_TOKEN` once, at start, so a token in the environment goes
  stale after 8 hours. A shim at `/usr/local/bin/gh` — ahead of the feature's
  `/usr/bin/gh` on `PATH` — fetches a fresh token and `exec`s the real one.
  **Verify** the github-cli feature's install path on both 24.04 and 26.04
  images.
- **`GH_TOKEN` in `~/.codespace-secrets`**: kept, but filled from the broker at
  `up` instead of the VM's account-wide `gh auth token`. Tools that read the
  variable once get a scoped token that may lapse; that is a strict improvement
  on an account-wide one that does not.
- **Removed from containers**: the https→ssh `insteadOf` rewrite,
  `GIT_SSH_COMMAND`, the authentication key in every form, and keyfile mode.

### 4.5 Permissions per token

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

### 4.6 Signing — a second key that cannot authenticate

*Checked*: GitHub accepts an SSH key registered as a **signing** key only
(`gh ssh-key add --type signing`). Such a key verifies commits and cannot log in
or push.

- New key `/persist/git/signing_ed25519`, registered on GitHub as signing-only.
- A second user agent, `ssh-agent-signing`, at a stable path beside the first
  (`/run/user/1000/ssh-agent-signing`), holding **only** that key.
- The launcher forwards that agent, not the main one, to
  `/mnt/git-ssh/agent.sock`. The mount path stays, so the dotfiles and the
  launcher's own signing config need no change.
- `user.signingkey` and `allowed_signers` point at the new public key.
- `ssh-auth` unlocks both keys.

The VM itself keeps the existing key for authentication and signing.

**Verify:**
- [ ] Commits signed by the old key stay "Verified" once it is no longer the
      container signing key. Keep it registered as a signing key on GitHub
      regardless.

---

## 5. Consequences to accept or solve

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
- **Revocation**: `codespace rm` drops the socket and revokes the cached token
  (`DELETE /applications/{client_id}/token`). Scoped tokens expire on their own
  regardless.

---

## 6. Phases

Each phase ships on its own and leaves the system working.

1. **Signing key on the VM.** The second key, registered as signing-only, its
   agent, and `ssh-auth` unlocking both. Containers are untouched.
2. **App and broker on the VM.** Register the app, `github-app-login`,
   `codespace-tokens.service`. Checked by hand with `curl --unix-socket`: a
   scoped token pushes to its repo and is refused by another. Containers still
   untouched.
3. **Containers switch — the hole closes here.** In one step: forward the
   signing agent instead of the main one, add the credential helper and `gh`
   shim, fill `GH_TOKEN` from the broker, and drop the https→ssh rewrite and
   keyfile mode. These cannot be split: taking the authentication key away
   before the token path exists leaves a container that cannot push at all. A
   launcher setting (`GITHUB_AUTH=app|legacy`, default `legacy` until this
   phase is proven) so one `codespace rebuild` moves a codespace either way.
4. **Parity.** `customizations.codespaces.repositories`, read-only on repos you
   cannot write, revocation on `rm`. Amend CLAUDE.md §3/§9, add the gotchas
   found, and make `app` the default.

### Rollback

Through phase 3, `GITHUB_AUTH=legacy` plus `codespace rebuild` restores today's
behaviour. The app can be uninstalled from GitHub at any time, which
invalidates every token it ever issued.

---

## 7. Checks before calling it done

- [ ] Every **verify** item above, answered and recorded in CLAUDE.md §8.
- [ ] In a codespace for repo A: `git push` to A works; `git push` to B fails;
      `gh pr create` on A shows **you** as author, not a bot.
- [ ] `ssh -T git@github.com` from a container fails: no key can authenticate.
- [ ] A commit made in a container shows "Verified" on GitHub.
- [ ] A codespace left running past 8 hours still pushes.
- [ ] After `codespace rm`, its cached token no longer works.
- [ ] A codespace with no `DOTFILES_REPOSITORY` still commits as you and signs
      (CLAUDE.md §6).
