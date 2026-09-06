{ config, lib, pkgs, gitIdentity, ... }:

{
  home.stateVersion = "26.05";

  programs.git = {
    enable = true;
    userName = gitIdentity.name;
    userEmail = gitIdentity.email;

    signing = {
      format = "ssh";
      # The *public* key: for ssh signing git hands this to `ssh-keygen -Y
      # sign`, which finds the private key at the same path without the .pub.
      key = "${gitIdentity.keyFile}.pub";
      signByDefault = true;
    };

    extraConfig = {
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
    matchBlocks."github.com" = {
      user = "git";
      identityFile = gitIdentity.keyFile;
      # Without this, ssh offers every key it can find and GitHub rejects the
      # connection after too many failures.
      identitiesOnly = true;
    };
  };

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
