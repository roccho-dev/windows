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
    paths = (with pkgs; [ bash coreutils git cacert openssh ]) ++ [ ghWrapper ghCredential ];
    pathsToLink = [ "/bin" "/etc/ssl" ];
  };

  # A trusted, single-user development image, not an own/rent runtime image.
  # Nix's database AND closure are seeded together by the existing Init pattern:
  # run this exact image with the empty nix volume at /seed, copy /nix/., then
  # mount that volume at /nix for use. Recreate with the same image identity.
  # A different image uses a fresh nix cache; retain work and the old cache for rollback.
  image = pkgs.dockerTools.buildLayeredImage {
    name = "ghcr.io/roccho-dev/windows-dev";
    tag = "nix";
    contents = [ profile pkgs.nix pkgs.curl ];
    includeNixDB = true;
    extraCommands = ''
      mkdir -p etc/nix home/dev tmp work/repos nix/var/nix/profiles
      chmod 1777 tmp
      printf 'root:x:0:0:Trusted development core:/home/dev:/bin/bash\n' > etc/passwd
      printf 'root:x:0:\n' > etc/group
      printf 'hosts: files dns\n' > etc/nsswitch.conf
      cat > etc/nix/nix.conf <<'EOF'
      experimental-features = nix-command flakes
      build-users-group =
      sandbox = false
      accept-flake-config = false
      EOF
      printf 'export PATH=/nix/var/nix/profiles/windows-dev/bin:/bin\n' > etc/profile
      ln -s ${profile} nix/var/nix/profiles/windows-dev
    '';
    config = {
      Cmd = [ "/bin/bash" "--login" ];
      WorkingDir = "/work/repos";
      Env = [
        "HOME=/home/dev"
        "USER=root"
        "NIX_REMOTE=local"
        "PATH=/nix/var/nix/profiles/windows-dev/bin:/bin"
        "NIX_SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
        "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
        "GIT_SSL_CAINFO=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
        "GIT_CONFIG_NOSYSTEM=1"
        "GIT_CONFIG_GLOBAL=/dev/null"
        "GIT_TERMINAL_PROMPT=0"
      ];
      # No anonymous volumes, published ports, daemon, host integration or auth import.
      Labels."org.opencontainers.image.source" = "https://github.com/roccho-dev/windows";
    };
  };
}
