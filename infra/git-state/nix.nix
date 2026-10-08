{ pkgs }:

let
  # Keep the exact v0.1.12 ELF unmodified; Nix executes it via its own glibc
  # loader instead of patching the Go release binary.
  gitBackendElf = pkgs.runCommand "terraform-backend-git-0.1.12-elf" {
    src = pkgs.fetchurl {
      url = "https://github.com/plumber-cd/terraform-backend-git/releases/download/v0.1.12/terraform-backend-git-linux-amd64";
      hash = "sha256-LumYYi0ryF7WaaGuZ6k+DNi564hn/IOda9bw9iLrDYA=";
    };
  } ''
    install -Dm755 "$src" "$out/bin/terraform-backend-git-elf"
  '';
  gitBackend = pkgs.writeShellScriptBin "terraform-backend-git" ''
    exec ${pkgs.stdenv.cc.bintools.dynamicLinker} \
      --library-path ${pkgs.glibc}/lib \
      ${gitBackendElf}/bin/terraform-backend-git-elf "$@"
  '';
in {
  # The actual pinned upstream executable is independent of the synthetic check.
  backend = gitBackend;
  fixture = pkgs.runCommand "git-state-finite-poc" {
  nativeBuildInputs = with pkgs; [
    bash coreutils curl git gnugrep jq openssh opentofu python3
  ];
} ''
  bash ${./proof.sh} ${./main.tf} ${gitBackend}/bin/terraform-backend-git "$out"
'';
}
