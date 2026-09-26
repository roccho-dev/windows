{
  description = "own and rent WSLC OCI images";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/35d3407a3816f3b341d8cf1d60abaf2b7b8166ac";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      own = import ./hosts/own/nix.nix { inherit pkgs; };
      devTools = pkgs.buildEnv {
        name = "rent-dev-tools";
        paths = with pkgs; [ coreutils git nodejs openssh python3 ];
        pathsToLink = [ "/bin" ];
      };
      sshConfig = pkgs.writeText "rent-sshd-config" (import ./hosts/rent/nix.nix {
        port = 2222;
        certFile = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
      });
      rentStart = pkgs.writeShellScriptBin "rent-start" ''
        set -eu
        ${pkgs.coreutils}/bin/chown 1000:1000 /home/dev
        ${pkgs.coreutils}/bin/install -d -m 700 -o 1000 -g 1000 /home/dev/.ssh
        if [ ! -s /home/dev/.ssh/authorized_keys ]; then
          if [ -z "''${RENT_AUTHORIZED_KEY:-}" ]; then
            echo "Set RENT_AUTHORIZED_KEY on first creation" >&2
            exit 1
          fi
          printf '%s\n' "$RENT_AUTHORIZED_KEY" > /home/dev/.ssh/authorized_keys
        fi
        ${pkgs.coreutils}/bin/chown 1000:1000 /home/dev/.ssh/authorized_keys
        ${pkgs.coreutils}/bin/chmod 600 /home/dev/.ssh/authorized_keys
        if [ ! -s /home/dev/.ssh/ssh_host_ed25519_key ]; then
          ${pkgs.openssh}/bin/ssh-keygen -q -t ed25519 -N "" -f /home/dev/.ssh/ssh_host_ed25519_key
        fi
        ${pkgs.coreutils}/bin/chmod 600 /home/dev/.ssh/ssh_host_ed25519_key
        exec ${pkgs.openssh}/bin/sshd -D -e -f ${sshConfig}
      '';
    in {
      packages.${system} = {
        own-image = pkgs.dockerTools.buildLayeredImage {
          name = "ghcr.io/roccho-dev/windows-own";
          tag = "nix";
          contents = [ pkgs.bash pkgs.cacert own.tools own.start ];
          extraCommands = ''
            mkdir -p etc home/dev tmp var/empty
            printf 'root:x:0:0:root:/root:/bin/sh\nsshd:x:74:74:sshd:/var/empty:/bin/sh\ndev:x:1000:1000:Development user:/home/dev:/bin/sh\n' > etc/passwd
            printf 'root:x:0:\nsshd:x:74:\ndev:x:1000:\n' > etc/group
            touch etc/profile
            chmod 1777 tmp
          '';
          config = {
            Cmd = [ "${own.start}/bin/own-start" ];
            Env = [ "HOME=/home/dev" "PATH=/bin:/usr/bin" ];
            ExposedPorts."2223/tcp" = {};
            Volumes."/home/dev" = {};
            Labels."org.opencontainers.image.source" = "https://github.com/roccho-dev/windows";
          };
        };
        rent-image = pkgs.dockerTools.buildLayeredImage {
          name = "ghcr.io/roccho-dev/windows-rent";
          tag = "nix";
          contents = [ pkgs.bash pkgs.cacert devTools rentStart ];
          extraCommands = ''
            mkdir -p etc home/dev tmp var/empty
            printf 'root:x:0:0:root:/root:/bin/sh\nsshd:x:74:74:sshd:/var/empty:/bin/sh\ndev:x:1000:1000:Development user:/home/dev:/bin/sh\n' > etc/passwd
            printf 'root:x:0:\nsshd:x:74:\ndev:x:1000:\n' > etc/group
            chmod 1777 tmp
          '';
          config = {
            Cmd = [ "${rentStart}/bin/rent-start" ];
            Env = [ "HOME=/home/dev" "PATH=/bin:/usr/bin" ];
            ExposedPorts."2222/tcp" = {};
            Volumes."/home/dev" = {};
            Labels."org.opencontainers.image.source" = "https://github.com/roccho-dev/windows";
          };
        };
      };
    };
}
