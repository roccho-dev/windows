{ pkgs }:

let
  # v0.1.12 upstream Linux amd64 release, SHA256 from the GitHub release asset.
  # The test runs the actual binary; neither HTTP backend nor Git storage is mocked.
  gitBackend = pkgs.runCommand "terraform-backend-git-0.1.12" {
    src = pkgs.fetchurl {
      url = "https://github.com/plumber-cd/terraform-backend-git/releases/download/v0.1.12/terraform-backend-git-linux-amd64";
      hash = "sha256-LumYYi0ryF7WaaGuZ6k+DNi564hn/IOda9bw9iLrDYA=";
    };
  } ''
    install -Dm755 "$src" "$out/bin/terraform-backend-git"
    # Upstream's CGO-enabled release expects the host /lib64 ELF interpreter.
    # Preserve its verified source digest; adapt only the ELF loader to locked Nix libc.
    "${pkgs.patchelf}/bin/patchelf" \
      --set-interpreter "$(cat ${pkgs.stdenv.cc}/nix-support/dynamic-linker)" \
      --set-rpath "${pkgs.glibc}/lib" "$out/bin/terraform-backend-git"
  '';
in
pkgs.runCommand "git-state-finite-poc" {
  nativeBuildInputs = with pkgs; [
    bash coreutils curl git gnugrep jq openssh opentofu python3
  ];
} ''
  bash ${./proof.sh} ${./main.tf} ${gitBackend}/bin/terraform-backend-git "$out"
''
