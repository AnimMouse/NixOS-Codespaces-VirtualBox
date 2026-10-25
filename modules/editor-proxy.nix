{ config, lib, pkgs, ... }:

let
  tlsDir = "/persist/tls";

  # One directory per editor port, holding that editor's unix socket. The hub's
  # is 8000; the launcher creates the rest and mounts each into its container
  # at /mnt/editor. nginx picks the directory by the port a request came in on,
  # so a new codespace needs no nginx change at all.
  #
  # setgid nginx: a subdirectory, and the socket code-server creates in it,
  # inherit the group, so the socket can be 0660 rather than world-writable —
  # observed with a bind()-created socket, not assumed. Only nginx and dev can
  # traverse it; a container sees only the one directory mounted into it.
  editorsDir = "/run/editors";
  ports = lib.range 8000 8010;

  editor-tls = pkgs.writeShellApplication {
    name = "editor-tls";
    runtimeInputs = with pkgs; [ openssl coreutils systemd ];
    text = builtins.replaceStrings
      [ "@TLS_DIR@" "@EXPORT_DIR@" ]
      [ tlsDir "${config.users.users.dev.home}/tls" ]
      (builtins.readFile ../scripts/editor-tls);
  };
in
{
  # Editors are shells — the hub's has sudo — so who reaches one matters more
  # than anything else on this machine. A shared password failed at that: every
  # container held the hub's, and could reach the hub. docs/EDITOR-MTLS.md has
  # the full reasoning; in short:
  #
  #  - nginx requires a client certificate signed by the VM's own CA. Your
  #    Firefox profile has it; containers and other Windows processes do not.
  #  - Every editor listens on a unix socket, not a port, so nginx is the only
  #    way in and the editors can run with --auth none.
  #  - nginx refuses any request a browser marks as cross-site or same-site
  #    (Fetch Metadata). Without a password, the certificate rides along on a
  #    hostile page's requests too, and code-server's own Origin check covers
  #    websockets only — its /proxy/<port>/ route would otherwise pass a
  #    cross-site POST straight to an app in the container. Tested.
  #
  # nginx rather than the socat proxy the plan began with, because closing that
  # last hole needs a proxy that reads HTTP. It also replaces the per-codespace
  # proxy units outright: this config is static, so there is nothing to start,
  # restart, or rate-limit per codespace.
  systemd.services.editor-tls = {
    description = "Create the editor CA, server and client certificates";
    wantedBy = [ "multi-user.target" ];
    before = [ "nginx.service" ];
    unitConfig.RequiresMountsFor = [ tlsDir config.users.users.dev.home ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = lib.getExe editor-tls;
    };
  };

  systemd.services.nginx = {
    requires = [ "editor-tls.service" ];
    after = [ "editor-tls.service" ];
  };

  services.nginx = {
    enable = true;

    # Only same-origin, user-initiated (a typed URL or the kiosk launcher), or
    # non-browser (header absent — such a client still needs the certificate).
    # same-site is refused too: localhost:8002 is same-site to localhost:8001,
    # since sites ignore ports, and one editor's pages have no business in
    # another's.
    appendHttpConfig = ''
      map $http_sec_fetch_site $editor_request_ok {
        default     0;
        ""          1;
        none        1;
        same-origin 1;
      }
    '';

    virtualHosts.editors = {
      default = true;
      onlySSL = true;
      listen = map (port: { addr = "0.0.0.0"; inherit port; ssl = true; }) ports;
      # HTTP/1.1, as tested: nginx cannot carry websockets over HTTP/2, and
      # one protocol is one less thing to reason about here.
      http2 = false;
      sslCertificate = "${tlsDir}/server.crt";
      sslCertificateKey = "${tlsDir}/server.key";

      extraConfig = ''
        ssl_client_certificate ${tlsDir}/ca.crt;
        ssl_verify_client on;

        if ($editor_request_ok = 0) {
          return 403;
        }

        # Uploads and large file saves; nginx's 1 MB default breaks dragging a
        # file into the editor.
        client_max_body_size 0;
      '';

      locations."/" = {
        proxyPass = "http://unix:${editorsDir}/$server_port/editor.sock:";
        proxyWebsockets = true;
        # code-server's websocket Origin check takes the host from Forwarded,
        # then X-Forwarded-Host, then Host (checked in 4.143.1's http.js).
        # So: not recommendedProxySettings, whose X-Forwarded-Host is $host
        # without the port and would refuse every connection — and the first
        # two cleared, so nothing a client sends can steer the check. An empty
        # value makes nginx drop the header.
        #
        # Host is rebuilt from $host and nginx's own port rather than passed
        # through as $http_host, which the build-time linter (gixy) rejects as
        # spoofable. It relies on each host-side forward using the same port
        # number as the guest, as the CLAUDE.md §3 table does.
        extraConfig = ''
          proxy_set_header Host $host:$server_port;
          proxy_set_header Forwarded "";
          proxy_set_header X-Forwarded-Host "";
          proxy_buffering off;
          proxy_request_buffering off;
          proxy_read_timeout 1d;
          proxy_send_timeout 1d;
        '';
      };
    };
  };

  systemd.tmpfiles.rules = [
    "d ${editorsDir}      2750 dev nginx -"
    "d ${editorsDir}/8000 2750 dev nginx -"
  ];
}
