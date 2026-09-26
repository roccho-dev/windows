# windows-dev definitions for Issue #2. Gate 1 (the exact source of the profile in use) and
# gate 2 (the existing GitHub owner-auth helper) are UNKNOWN: nothing here ports, wraps or
# replaces gh, and neither output below is the accepted final runtime.
{ pkgs }: rec {
  # Helper-free tools that the Tools step realizes into /nix/var/nix/profiles/windows-dev.
  profile = pkgs.buildEnv {
    name = "windows-dev";
    paths = with pkgs; [ bash coreutils git cacert ];
    pathsToLink = [ "/bin" "/etc/ssl" ];
  };

  # DRAFT only, not built or run: no win.ps1 step, Spec or Binding refers to it, and the run
  # definition accepts only the pinned official nixos/nix image. The image's /nix (store,
  # registered DB, windows-dev profile link) is the seed source for an empty nix volume through
  # Init's /seed copy and marker. A nix volume stays bound to the one image digest that seeded
  # it; another image needs a new or reseeded volume. Widening spec.json's image pattern is part
  # of acceptance. Nix already treats /nix/var/nix/profiles as a GC root directory.
  imageDraft = pkgs.dockerTools.buildLayeredImage {
    name = "windows-dev-draft";
    tag = "unaccepted";
    contents = [ profile pkgs.nix ];
    includeNixDB = true;
    extraCommands = ''
      mkdir -p etc/nix home/dev tmp work/repos nix/var/nix/profiles
      chmod 1777 tmp
      # Root for now (Issue #2's dev user is a P decision); HOME=/home/dev stays disposable.
      echo 'root:x:0:0:root:/home/dev:/bin/sh' > etc/passwd
      echo 'root:x:0:' > etc/group
      # Single-user root Nix; WSLC denies the namespaces a build sandbox needs.
      printf 'build-users-group =\nexperimental-features = nix-command flakes\nsandbox = false\n' > etc/nix/nix.conf
      ln -s ${profile} nix/var/nix/profiles/windows-dev-1-link
      ln -s windows-dev-1-link nix/var/nix/profiles/windows-dev
    '';
    config = {
      Env = [
        "HOME=/home/dev"
        "PATH=/nix/var/nix/profiles/windows-dev/bin:/bin"
        "SSL_CERT_FILE=/nix/var/nix/profiles/windows-dev/etc/ssl/certs/ca-bundle.crt"
      ];
      WorkingDir = "/work/repos";
      Labels."org.opencontainers.image.source" = "https://github.com/roccho-dev/windows";
      Labels."org.roccho-dev.windows.acceptance" = "draft: Issue #2 gates 1 and 2 UNKNOWN";
    };
  };
}