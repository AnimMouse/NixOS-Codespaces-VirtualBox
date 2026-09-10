{ config, lib, pkgs, gitIdentity, ... }:

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

      # Everything github goes over SSH even when the remote was written as an
      # https URL. This is what makes `codespace up github.com/you/private-repo`
      # work: the launcher clones the https form, and git rewrites it to the key
      # that GitHub actually authenticates.
      url."git@github.com:".insteadOf = [
        "https://github.com/"
        "github.com:"
      ];
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
  # to prompt at — which is every container the launcher creates, and the
  # dotfiles clone in particular. The agent holds the decrypted key, and only
  # its socket is handed to containers, so the key itself never leaves the VM.
  #
  # Socket is $XDG_RUNTIME_DIR/ssh-agent, i.e. /run/user/1000/ssh-agent: the
  # same path every login, which is what makes a container created in one
  # session still work in the next.
  services.ssh-agent.enable = true;

  # For the API — creating repos, opening PRs. Git transport stays on SSH so
  # there is only one credential that can expire, and it never does.
  programs.gh = {
    enable = true;
    settings.git_protocol = "ssh";
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
