# Editor access by client certificate — plan, not built

Replace the shared editor password with a **client certificate in Firefox**,
checked by the proxy that already sits in front of every editor, and take the
editors off the network entirely so that the proxy is the only way in.

Nothing here is implemented yet. Facts marked *checked* were read from source,
`--help` output or the nixpkgs option tree, or observed; facts marked **verify**
must be confirmed before or during the build, and the design bends if they turn
out false.

---

## 1. Why

An editor is a shell. The hub editor is a shell on the VM as `dev`, who has
passwordless sudo — so whoever reaches the hub editor is root on the VM.

Today one password guards all of them, and it does not hold:

| Problem | Observed |
|---|---|
| **Every container knows the hub password.** The launcher starts each container's code-server with `-e PASSWORD=$(editor_password)` — the same `/persist/code-server/pw` the hub uses — so it is in that process's environment, readable by anything running as the remote user | *checked* (`scripts/codespace`, `cmd_up`) |
| **Every container can reach the hub.** The firewall opens 8000–8010 on all interfaces, `docker0` included, so `172.17.0.1:8000` answers from inside a codespace | *checked* — `curl` from the dev-vm codespace got `302` |
| **Every container can reach every other editor**, both through the VM's ports and directly at the other container's bridge address on 8080 | follows from the above and the default bridge network |

Taken together: a dependency's install script, a malicious extension or an
agent in *any* codespace can log in to the hub editor and become root on the
VM. The read-only design of `modules/vm-control.nix` means nothing until this
is closed.

The password is also a chore — copied per browser profile, and the only
credential in this design that a human has to transport by hand on every
reinstall.

### Why not just give each codespace its own password

It fixes the first row, and a firewall rule restricting 8000–8010 to the NAT
interface fixes the second. It does not fix the third (container to container
on the bridge), and it leaves a string to copy for every codespace instead of
one. The design below fixes all three with one mechanism.

### Why not an SSH tunnel instead of the NAT forward

The tunnel's local end is still a port on Windows that any local process can
connect to. It moves the problem, it does not authenticate the browser.

---

## 2. Design

```
Firefox (codespace profile, holds client cert)
   │  https://localhost:800N      ← NAT forward, 127.0.0.1 on Windows (§3, unchanged)
   ▼
VM :800N  socat OPENSSL-LISTEN  verify=1  cafile=client-CA
   │                            ← no cert, no connection: the TLS handshake fails
   ▼
UNIX-CONNECT /run/codespace/<name>/editor.sock
   │                            ← bind-mounted directory, owned by dev
   ▼
container: code-server --socket /mnt/editor/editor.sock --auth none
```

Two changes do the work:

1. **The proxy terminates TLS and requires a client certificate.** It already
   exists (`codespace-proxy@`), it already runs socat, and socat can do this
   with options alone. *checked*: socat 1.8.1.3 from nixos-26.05 has
   `OPENSSL-LISTEN`, `cafile`, `verify`, `openssl-min-proto-version` and
   `UNIX-CONNECT`.
2. **The editor listens on a unix socket, not a TCP port.** code-server has
   `--socket`; *checked* for the hub too: nixpkgs 26.05's `services.code-server`
   has `socket` and `socketMode` options. A socket in a directory mounted from
   the VM is reachable from the VM and from inside that one container, and from
   nowhere on any network. So the editor can run with `--auth none`: the only
   path to it is the proxy, and the proxy has already checked the certificate.

Nothing in §3 moves: still NAT, still `127.0.0.1` forwards, still distinct
ports, still `localhost` — which stays a secure context over https as it was
over http.

### 2.1 Certificates — `/persist/tls`, made on first boot

A oneshot unit, `editor-tls.service`, in the shape of `code-server-password`:
if a file is absent it is generated, and nothing is ever overwritten.

| File | What | Validity |
|---|---|---|
| `ca.key`, `ca.crt` | The VM's own CA. Signs the server cert and client certs | 10 years |
| `server.key`, `server.crt` | One cert for every editor port — certificates are not per-port. SAN `DNS:localhost`, `IP:127.0.0.1` | 2 years, regenerated when within 30 days of expiry |
| `client.p12` | Your browser's identity: key + cert + CA chain, for one-time import | 2 years |

ECDSA P-256 throughout; OpenSSL, socat and Firefox all handle it.

**The CA is name-constrained** to `DNS:localhost` and `IP:127.0.0.1/32`.
Importing a CA into Firefox normally lets it vouch for *any* website; with
`nameConstraints` (critical) a leaked `ca.key` can mint certificates for
`localhost` and nothing else. **verify**: Firefox enforces name constraints on
a user-imported root — NSS does, but confirm with a deliberately out-of-scope
cert that it is rejected.

`/persist/tls` is `0700 root`. Like `/persist/ssh`, it is never mounted into a
container, and it joins `InaccessiblePaths` in `modules/vm-control.nix`.

The `.p12` needs a passphrase for import. Generated and logged once to the
journal, exactly as the editor password is today — the one string you still
copy, once per reinstall-of-Windows rather than once per editor.

### 2.2 The proxy — `codespace-proxy@`

```
socat OPENSSL-LISTEN:$port,fork,reuseaddr,cert=…/server.pem,cafile=…/ca.crt,verify=1,openssl-min-proto-version=TLS1.2 \
      UNIX-CONNECT:/run/codespace/$name/editor.sock
```

- It no longer resolves the container's bridge address. That lookup, and its
  failure mode when the container is recreated, go away.
- `verify=1` with `cafile` = the VM's CA: a client without a certificate signed
  by it fails the handshake. **verify**: socat sends the CA list in its
  CertificateRequest, so Firefox offers the right certificate unprompted.
- Byte-level, so websockets pass through untouched.

### 2.3 The editor — inside each container

- `/run/codespace/<name>/` on the VM (tmpfiles `d /run/codespace 0755 dev users`,
  the launcher creates the per-codespace directory), mounted at `/mnt/editor`.
  The directory, not the socket file, for the reason given in
  `modules/vm-control.nix`: a file bind mount pins the inode, and code-server
  recreates its socket on every start. Under `/mnt` beside `/mnt/git-ssh` and
  `/mnt/vm`, where §8 says plumbing goes.
- `code-server --socket /mnt/editor/editor.sock --socket-mode 600 --auth none`,
  started as the remote user (uid 1000, as `dev` on the VM, so the proxy and the
  launcher can both reach it).
- The launcher's "is the editor up" probe becomes
  `curl --unix-socket /run/codespace/<name>/editor.sock http://x/healthz` —
  still asking the thing itself (§8, `pgrep`), just over a different transport.
- `PASSWORD` is no longer passed. Nothing in a container holds an editor
  credential of any kind.

### 2.4 The hub editor

`services.code-server.socket = "/run/code-server/hub.sock"` and an instance of
the same TLS proxy on 8000. The hub then has no TCP listener at all, and the
firewall can close 8000–8010 on everything but the NAT interface for good
measure — defence in depth, since the handshake already refuses.

### 2.5 Firefox — once per profile

Into the `codespace` profile that `codespace-kiosk.ps1` already uses:

1. Settings → Privacy & Security → Certificates → View Certificates
2. *Your Certificates* → Import → `client.p12`, with the passphrase
3. *Authorities* → Import → `ca.crt`, trust for websites
4. `about:config`: `security.default_personal_cert` = `Select Automatically`,
   so no certificate chooser on each connection

`/persist/tls` is root-only, so the unit also leaves a `dev`-readable copy of
exactly these two files in `/persist/home/dev/tls/`, and from Windows:
`scp -P 2222 "dev@localhost:tls/*" .` — then delete that copy on the VM.

**verify**: Firefox enterprise policies (`policies.json`) document installing a
CA but not a client certificate, so step 2 stays manual. Step 3 could be a
policy; not worth the asymmetry.

The kiosk launcher switches to `https://`. Any other Firefox profile used for
editors needs the same import — the cost of doing this per profile is the
point: a profile without the certificate cannot get in.

---

## 3. Consequences to accept or solve

- **Revocation is rotation.** socat has no CRL option (*checked*: none in
  `socat -hhh`). A lost `client.p12` means deleting `/persist/tls`, letting the
  unit regenerate everything, and re-importing — two files, one profile. For a
  single user that is acceptable; for anything more it would not be.
- **The `.p12` on Windows is the credential.** Anyone who copies it and its
  passphrase can reach the editors — but only from that Windows machine, since
  the forwards are bound to `127.0.0.1`. Same reach as the password today,
  without the copies inside every container.
- **Other local processes on Windows** still reach the port, and now fail the
  handshake instead of meeting a login page. Strictly better.
- **DNS rebinding** stops working: a hostile name resolved to `127.0.0.1` gets a
  server certificate for `localhost`, and Firefox refuses the connection.
- **Cross-site requests are the real residual risk, and the most important
  check in this plan.** Firefox presents the client certificate on *any*
  request to `https://localhost:800N`, including one a hostile web page makes
  from another origin. With `--auth none` there is no cookie or password left
  to stop it, so a cross-site WebSocket to the editor is stopped by exactly one
  thing: code-server's Origin check on websocket upgrades. **verify**, by
  attempting it from a page on another origin, that the upgrade is refused —
  and that it still is behind the proxy, where code-server sees plain HTTP on
  its socket while the browser spoke https (if the check rejects legitimate
  traffic there, `--trusted-origins` exactly `localhost:800N`, never a
  wildcard). If code-server does not check, this design needs an Origin check
  of its own in the proxy, which socat cannot do — stop and rethink.
  Using the kiosk profile *only* for editors, as it already is, narrows this:
  a hostile page has to be open in that profile to try.
- **The first visit after the switch** hits the old `http://` URL, now speaking
  TLS. Firefox shows a protocol error rather than redirecting. Acceptable; the
  launcher prints the new URL.
- **Real Codespaces is unaffected.** Nothing here touches `devcontainer.json`;
  the socket, the mount and `--auth none` are all supplied by the launcher.

---

## 4. Phases

Each phase leaves a working system, and the password keeps working until the
last one.

1. **Certificates.** `editor-tls.service` and `/persist/tls`. No behaviour
   change. Import into Firefox.
2. **TLS at the proxy, TCP behind it.** `codespace-proxy@` switches to
   `OPENSSL-LISTEN … verify=1`, still connecting to `$ip:8080`, password still
   on. Proves the Firefox side in isolation: `https://` with the certificate
   works, without it the handshake fails, and the editor still asks for its
   password.
3. **Editors on sockets.** Launcher mounts `/mnt/editor`, starts code-server
   with `--socket … --auth none`, proxy switches to `UNIX-CONNECT`. Per
   codespace, on `codespace rebuild` — an old container keeps TCP and the
   password until rebuilt, and the launcher reads which one it has, as it does
   for the agent socket.
4. **Hub on a socket.** `services.code-server.socket`, its own proxy instance
   on 8000. This is the step that closes root-via-hub.
5. **Retire the password.** Drop `PASSWORD` from the launcher,
   `code-server-password.service`, `PW_FILE`, the `password:` line in `up`'s
   output; tighten the firewall to the NAT interface.

### Rollback

Phases 2–4 are each one unit's `ExecStart` and one launcher branch. Reverting
the commit and `rebuild` restores password auth over http; containers created
under phase 3 need `codespace rebuild` to get a TCP editor back. Phase 1's files
on `/persist/tls` are inert without the rest.

---

## 5. Checks before calling it done

From the dev-vm codespace, after phase 5:

- `curl -k https://172.17.0.1:8000/` fails in the TLS handshake.
- `curl http://<another container's ip>:8080/` is refused — nothing listens.
- `env | grep -i password` and `cat /proc/*/environ` show no editor credential.
- `ls /mnt/editor` shows this codespace's socket only.

From Windows:

- The kiosk profile opens every editor with no prompt and no password.
- A fresh Firefox profile gets a handshake error on every port.
- A cert signed by the VM CA for `example.com` is rejected by Firefox (name
  constraints honoured).
- A page served from another origin, opened in the kiosk profile, cannot open
  a websocket to any editor port (§3, cross-site requests).
