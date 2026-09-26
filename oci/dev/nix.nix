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
  # definition accepts only the pinned official nixos/nix image. How this image's /nix closure
  # relates to the mounted nix volume (seed per image digest, or realize in the volume) is undecided.
  imageDraft = pkgs.dockerTools.buildLayeredImage {
    name = "windows-dev-draft";
    tag = "unaccepted";
    contents = [ profile pkgs.nix ];
    extraCommands = ''
      mkdir -p home/dev tmp work/repos
      chmod 1777 tmp
    '';
    config = {
      Env = [
        "HOME=/home/dev"
        "PATH=/nix/var/nix/profiles/windows-dev/bin:/bin"
        "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
      ];
      WorkingDir = "/work/repos";
      Labels."org.opencontainers.image.source" = "https://github.com/roccho-dev/windows";
      Labels."org.roccho-dev.windows.acceptance" = "draft: Issue #2 gates 1 and 2 UNKNOWN";
    };
  };
}