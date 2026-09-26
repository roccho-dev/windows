# windows-dev definitions for Issue #2. Gates 1 and 2 (the exact source of the profile in use and the existing
# owner-auth helper) remain open; this profile is the bounded CI0 bootstrap, not F1 acceptance.
{ pkgs }: rec {
  # One-owner GitHub routing per execution.md: a gh wrapper and a git credential helper, immutable outputs that call
  # the absolute in-closure gh with that owner's root as GH_CONFIG_DIR. Tools binds each clone to the helper; Run
  # excludes system and global Git configuration and prompts.
  ghRoot = "/work/repos/.auth/roccho-dev/gh";
  ghWrapper = pkgs.writeShellScriptBin "gh" ''
    export GH_CONFIG_DIR=${ghRoot}
    exec ${pkgs.gh}/bin/gh "$@"
  '';
  ghCredential = pkgs.writeShellScriptBin "git-credential-github-roccho-dev" ''
    export GH_CONFIG_DIR=${ghRoot}
    exec ${pkgs.gh}/bin/gh auth git-credential "$@"
  '';

  # The tools that the Tools step realizes into /nix/var/nix/profiles/windows-dev.
  profile = pkgs.buildEnv {
    name = "windows-dev";
    paths = (with pkgs; [ bash coreutils git cacert ]) ++ [ ghWrapper ghCredential ];
    pathsToLink = [ "/bin" "/etc/ssl" ];
  };
}