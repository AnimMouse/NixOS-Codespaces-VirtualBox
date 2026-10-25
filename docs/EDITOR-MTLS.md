# Editor access by client certificate

Every editor — the hub and each codespace's — is reached only through nginx on
the VM, which requires a **client certificate in Firefox** signed by the VM's
own CA. The editors listen on unix sockets, not ports, so nginx is the only way
in, and they run with no password at all.

Built in `modules/editor-proxy.nix`, `modules/code-server.nix`,
`scripts/editor-tls` and the launcher. Facts marked *tested* were exercised in
a container against the real code-server 4.143.1, nginx 1.30 and the exact
nginx config NixOS generates; facts marked **verify** need Firefox or the VM
and are listed in §5.

---

## 1. Why

An editor is a shell. The hub editor is a shell on the VM as `dev`, who has
passwordless sudo — so whoever reaches the hub editor is root on the VM.

Before this, one password guarded all of them, and it did not hold:

| Problem | How it was found |
|---|---|
| **Every container knew the hub password.** The launcher started each container's code-server with `-e PASSWORD=…` — the same `/persist/code-server/pw` the hub used — so it sat in that process's environment | read in `scripts/codespace` |
| **Every container could reach the hub.** The firewall opens 8000–8010 on all interfaces, `docker0` included | `curl` from the dev-vm codespace to `172.17.0.1:8000` got `302` |
| **Every container could reach every other editor**, through the VM's ports and directly on the bridge at port 8080 | follows from the above |

So a dependency's install script, a malicious extension or an agent in *any*
codespace could log in to the hub and become root on the VM.

---

## 2. Design

```
Firefox (profile holding the client certificate)
   │  https://localhost:800N        ← NAT forward, 127.0.0.1 on Windows (§3, unchanged)
   ▼
VM :800N  nginx  ssl_verify_client on, cafile = the VM's CA
   │              Sec-Fetch-Site must be same-origin, none, or absent
   ▼
unix:/run/editors/800N/editor.sock  ← picked by $server_port; dir setgid nginx
   │                                  (bind-mounted into the container)
   ▼
code-server --socket /mnt/editor/editor.sock --auth none
```

Nothing in CLAUDE.md §3 moves: still NAT, still `127.0.0.1` forwards, still
distinct ports, still `localhost`.

### 2.1 Why nginx, not socat

The first version of this plan kept the existing socat proxy and added
`verify=1`. Testing found the hole that sinks it: Firefox presents the client
certificate on **any** request to `localhost:800N`, including one a hostile
page makes from another site. With `--auth none` there is no cookie left to
stop it, and code-server's own Origin check covers websockets only — its
`/proxy/<port>/` route passed a cross-site POST straight to an app running in
the container (*tested*). The old password cookie was `SameSite=lax`, so this
would have been a regression.

Closing it needs a proxy that reads HTTP. nginx rejects by Fetch Metadata,
which Firefox sets on every request: only `same-origin`, `none` (typed URL,
bookmark, the kiosk launcher) and absent (non-browser clients, which still need
the certificate) pass. `same-site` is refused as well — sites ignore ports, so
another editor's page is same-site.

Side benefit: the config is static. The per-codespace `codespace-proxy@` units,
their address re-resolution, their start-rate-limit handling and `reset-failed`
are gone.

### 2.2 Certificates — `/persist/tls`, made on first boot

`editor-tls.service`, a oneshot ordered before nginx. Nothing that exists is
overwritten; a certificate the current CA did not sign is remade.

| File | What |
|---|---|
| `ca.key`, `ca.crt` | The VM's CA. **Name-constrained** (critical) to `DNS:localhost` and `IP:127.0.0.1`, so Firefox's trust in it cannot extend to any other site even if `ca.key` leaked. OpenSSL rejects an out-of-scope cert with "permitted subtree violation" (*tested*) |
| `server.key`, `server.crt` | One certificate for every editor port. SAN `localhost`, `127.0.0.1` |
| `client.key`, `client.crt`, `client.p12`, `client.pass` | Your browser's identity, packaged for import, and the passphrase Firefox requires |

ECDSA P-256; the `.p12` is PBES2/AES-256. **Ten years for all three**, where
the plan said two with automatic server renewal: browsers' leaf-lifetime limits
apply to public CAs, not a privately imported root (**verify** in Firefox), and
every renewal is a manual re-import. Rotation is the revocation story anyway.

`/persist/tls` is `0750 root:nginx`; nginx can read `ca.crt` and the server
pair, nothing else. On first creation a `dev`-readable copy of `client.p12`
and `ca.crt` goes to `~/tls` for `scp`, and the passphrase is logged once. Like
`/persist/ssh`, the directory is never mounted into a container, and
`vm-control` cannot see it or `editor-tls`'s journal.

Idempotent, rotation (delete the CA, everything is reissued and verifies) and a
lost `.p12` alone were all *tested*.

### 2.3 nginx

- `ssl_verify_client on` against `ca.crt`. No certificate, or one from another
  CA: `400` (*tested*).
- The Fetch Metadata rule above, as a `map` and one `if` (*tested*: same-site
  and cross-site `403`, a cross-site POST to `/proxy/` never reaches the app).
- `proxy_pass http://unix:/run/editors/$server_port/editor.sock:` — the socket
  by port, so a new codespace needs no nginx change (*tested*).
- Websockets proxied, HTTP/1.1 only (*tested*, `101`).
- **Host and forwarding headers.** code-server's websocket Origin check takes
  the host from `Forwarded`, then `X-Forwarded-Host`, then `Host` (read in its
  `http.js`). So no `recommendedProxySettings` — its `X-Forwarded-Host` has no
  port and would refuse every websocket — and both forwarding headers are
  cleared so a client cannot steer the check (*tested*). `Host` is
  `$host:$server_port`: the build-time gixy lint rejects `$http_host`, and the
  port matches because §3 forwards each port to the same number.
- `client_max_body_size 0` — nginx's 1 MB default would break file uploads
  (*tested* with 2 MB).

### 2.4 The editors

- `/run/editors` is `2750 dev:nginx`. A directory made inside it, and a socket
  made inside that, inherit the nginx group, so sockets are `0660` and nginx
  reaches them through the group alone (*tested* with nginx's workers running
  as a user whose only access was the group).
- The launcher makes `/run/editors/<port>` with `sudo install -d -m 2750` on
  every `up`. Not `mkdir` + `chmod`: Linux clears the setgid bit on a `chmod`
  by a user outside the group, which produced a socket nginx could not open
  (*found in testing*). Every `up`, because `/run` is a tmpfs and docker will not
  start a container whose bind-mount source is missing.
- Mounted at `/mnt/editor`, beside `/mnt/git-ssh` and `/mnt/vm`. The directory,
  not the socket: code-server replaces its socket on every start (*tested*: it
  also takes over a stale one, and removes its own on exit).
- `code-server --socket /mnt/editor/editor.sock --socket-mode 660 --auth none`.
  No `PASSWORD`; nothing in a container holds a credential for any editor.
- The launcher's liveness probe is `curl --unix-socket … /healthz` — still the
  editor itself answering, never a process listing.
- A container created before this has no `/mnt/editor`, and mounts are fixed at
  create, so `up` brings it up shell-only — `codespace shell` works — and says
  to `codespace rebuild` it for the editor.
- The hub: `services.code-server.socket = "/run/editors/8000/editor.sock"`,
  `auth = "none"`, and an `ExecStartPre` that makes its directory, since tmpfiles
  is not ordered before it on a switch.

---

## 3. Consequences

- **Revocation is rotation.** `sudo rm -r /persist/tls && sudo systemctl
  restart editor-tls`, then re-import. For one person, fine.
- **The `.p12` on Windows is the credential.** It reaches the editors only from
  that machine, since the forwards are bound to `127.0.0.1`.
- **Other local processes on Windows**, and every container, get `400` instead
  of a login page.
- **DNS rebinding** fails: a hostile name resolved to `127.0.0.1` gets a
  certificate for `localhost` and Firefox refuses it.
- **Links into an editor from elsewhere are refused** (`403`) — another site,
  or another editor's port. Open editors by URL, bookmark or the kiosk
  launcher.
- **code-server's `/proxy/<port>/` previews are same-origin with the editor.**
  A web app you preview that way runs its scripts on the editor's origin and
  could drive it. That was equally true with the password, is code-server's
  design, and the Fetch Metadata rule cannot see it. Preview only what you
  would run in the editor's terminal anyway.
- **Real Codespaces is unaffected.** Nothing touches `devcontainer.json`.

---

## 4. Cutover

Built as one change rather than the five phases first planned: with nginx the
proxy, the sockets and `--auth none` depend on each other, and the
intermediate states would each have needed code thrown away a phase later.

0. Over SSH, not in an editor — the editors go away in step 1:
   `sudo systemctl stop 'codespace-proxy@*'`. The switch should stop them as
   units that no longer exist, but a socat left holding 8001 would stop nginx
   binding at all, taking every editor down with it.
1. `rebuild --pull`. `editor-tls` makes `/persist/tls` and logs the passphrase;
   nginx takes 8000–8010; the hub moves to its socket. **Every codespace editor
   is unreachable from here** until step 3.
2. Import the certificate (README, setup step 5).
3. `codespace rebuild <name>` for each codespace, over SSH. Each needs it once,
   for the `/mnt/editor` mount.

The old password file `/persist/code-server/pw` is no longer read; delete it.

### Rollback

`git revert` and `rebuild`: nginx goes, the hub returns to `0.0.0.0:8000` with
the password unit, and `codespace rebuild` puts each container back on TCP.
`/persist/tls` is inert without the rest.

---

## 5. Checks on the VM and in Firefox

What a container cannot test:

- [x] The `codespace` profile opens the editors with no password, after the
      import (confirmed by the user).
- [ ] A fresh Firefox profile gets `400` on every port.
- [x] From the dev-vm codespace: `curl -k https://172.17.0.1:8000/` and
      `…:8001/` get `400`, and nothing answers on port 8080 on the bridge.
- [x] No `PASSWORD` in a codespace's environment or any of its processes'.
- [ ] Firefox accepts the ten-year server certificate under the imported root.
- [ ] Firefox rejects a certificate the CA signs for `example.com`
      (name constraints honoured, as OpenSSL does).
- [ ] VS Code webviews (Markdown preview, an extension's panel) still load —
      they run in iframes, and their requests must count as same-origin for
      the Fetch Metadata rule.
- [ ] A page served from another origin, opened in the kiosk profile, cannot
      open a websocket or POST to any editor port.
