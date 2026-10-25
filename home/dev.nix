{ config, lib, pkgs, gitIdentity, ... }:

let
  # The VM authenticates to GitHub with the GitHub App, as codespaces do
  # (docs/GITHUB-APP.md §6.1): the same helper and gh shim the containers
  # run, pointed at the broker's socket on the VM, where it answers with the
  # account-wide token. The SSH key is left one job, signing — a leaked key
  # can sign, and push nowhere.
  tokenSock = "${gitIdentity.authDir}/token.sock";
  clientEnv = ''
    export CODESPACE_TOKEN_SOCK=${tokenSock}
    PATH=${lib.makeBinPath (with pkgs; [ curl coreutils gnused ])}:$PATH
  '';
  # dash, as in the containers' images: the clients are POSIX sh.
  git-credential-github-app = pkgs.writeShellScript "git-credential-github-app" ''
    ${clientEnv}
    exec ${lib.getExe pkgs.dash} ${../scripts/git-credential-codespace} "$@"
  '';
  # gh reads its token once, at start, and the account token lasts 8 hours:
  # a fresh one per run, ahead of anything `gh auth login` stored. The shim
  # finds the real gh on PATH, skipping itself.
  gh-github-app = pkgs.writeShellScriptBin "gh" ''
    ${clientEnv}
    PATH=${pkgs.gh}/bin:$PATH exec ${lib.getExe pkgs.dash} ${../scripts/gh-codespace} "$@"
  '';
in
{
  home.stateVersion = "26.05";

  programs.git = {
    enable = true;

    signing = {
      format = "ssh";
      # The *public* key: for ssh signing git hands this to `ssh-keygen -Y
      # sign`, which finds the private key at the same path without the .pub.
      key = "${gitIdentity.keyFile}.pub";
      signByDefault = true;
    };

    # One freeform attrset, mirroring gitconfig's own structure. `userName`,
    # `userEmail` and `extraConfig` were all folded into this.
    # Your name and email come from here, not from this repo. A missing include
    # is silently ignored by git, so a VM without one simply has no identity and
    # says so on the first commit — rather than authoring as someone else.
    includes = [ { path = gitIdentity.identityFile; } ];

    settings = {
      gpg.ssh.allowedSignersFile = gitIdentity.allowedSigners;

      init.defaultBranch = "main";
      pull.rebase = true;
      push.autoSetupRemote = true;
      rebase.autoStash = true;

      # Everything github goes over https, with the app's token, even when a
      # remote was written for SSH — the key no longer authenticates anywhere.
      # Checkouts made before the switch keep git@github.com: remotes, and
      # this is what lets them still push.
      url."https://github.com/".insteadOf = [
        "git@github.com:"
        "ssh://git@github.com/"
        "github.com:"
      ];

      # The empty entry clears any helper set before this one, so a stray
      # `gh auth git-credential` or a cache cannot answer first.
      credential."https://github.com".helper = [ "" "${git-credential-github-app}" ];
    };
  };

  programs.ssh = {
    enable = true;

    # The implicit `Host *` block is on its way out, so spell it out. These are
    # exactly home-manager's own outgoing defaults — copied verbatim so
    # that turning the option off changes nothing about the generated config.
    enableDefaultConfig = false;

    settings = {
      # entryBefore keeps this ahead of `Host *`. Nothing currently overlaps, but
      # ssh_config takes the *first* value it sees for a keyword, so a specific
      # block that lands after the wildcard silently stops winning.
      "github.com" = lib.hm.dag.entryBefore [ "*" ] {
        User = "git";
        IdentityFile = gitIdentity.keyFile;
        # Without this, ssh offers every key it can find and GitHub rejects the
        # connection after too many failures.
        IdentitiesOnly = true;
      };

      "*" = {
        ForwardAgent = false;
        # "yes", against home-manager's old default of "no": the signing key
        # has a passphrase, and this means the first ssh of the boot adds it to
        # the agent after one prompt instead of asking on every single
        # connection.
        AddKeysToAgent = "yes";
        Compression = false;
        ServerAliveInterval = 0;
        ServerAliveCountMax = 3;
        HashKnownHosts = false;
        UserKnownHostsFile = "~/.ssh/known_hosts";
        ControlMaster = "no";
        ControlPath = "~/.ssh/master-%r@%n:%p";
        ControlPersist = "no";
      };
    };
  };

  # A passphrase-protected key cannot be used by anything that has no terminal
  # to prompt at — the VM's signing service for codespaces among them. The
  # agent holds the decrypted key; GITHUB_AUTH=legacy also hands its socket to
  # containers, so the key itself never leaves the VM.
  #
  # Socket is $XDG_RUNTIME_DIR/ssh-agent, i.e. /run/user/1000/ssh-agent: the
  # same path every login, which is what makes a container created in one
  # session still work in the next.
  services.ssh-agent.enable = true;

  # For the API — opening PRs, reading issues — on the app's token, fetched
  # per run. Its permissions are the ceiling: whatever the app was registered
  # with (docs/GITHUB-APP.md §4.1). git's helper is the broker's, above, not
  # gh's own, which would hand git whatever `gh auth login` stored.
  programs.gh = {
    enable = true;
    package = pkgs.symlinkJoin {
      name = "gh-github-app-${pkgs.gh.version}";
      # First wins: bin/gh is the shim; completions and man pages are gh's.
      paths = [ gh-github-app pkgs.gh ];
      # home-manager calls getExe on it.
      meta.mainProgram = "gh";
    };
    gitCredentialHelper.enable = false;
    settings.git_protocol = "https";
  };

  programs.bash = {
    enable = true;
    historyControl = [ "ignoredups" "ignorespace" ];
    historySize = 10000;
    shellAliases = {
      g = "git";
      gs = "git status --short --branch";
      gl = "git log --oneline --graph --decorate -20";
      cs = "codespace";
    };
  };

  programs.tmux = {
    enable = true;
    terminal = "screen-256color";
    historyLimit = 10000;
    escapeTime = 10;
    keyMode = "vi";
  };

  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };
}
