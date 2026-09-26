{
  description = "own and rent WSLC OCI images";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/35d3407a3816f3b341d8cf1d60abaf2b7b8166ac";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      ownSpec = builtins.fromJSON (builtins.readFile ./hosts/own/spec.json);
      own = import ./hosts/own/nix.nix { inherit pkgs; spec = ownSpec; };
      dev = import ./oci/dev/nix.nix { inherit pkgs; };
      ownConfig = {
        Cmd = [ "${own.start}/bin/own-start" ];
        Env = [ "HOME=${ownSpec.stateMount}" "PATH=/bin:/usr/bin" ];
        ExposedPorts."${toString ownSpec.sshPort}/tcp" = {};
        Volumes.${ownSpec.stateMount} = {};
        Labels."org.opencontainers.image.source" = "https://github.com/roccho-dev/windows";
      };
      devTools = pkgs.buildEnv {
        name = "rent-dev-tools";
        paths = with pkgs; [ coreutils git openssh ];
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
          name = ownSpec.imageRepository;
          tag = "nix";
          contents = [ pkgs.bash pkgs.cacert own.tools own.start ];
          extraCommands = ''
            mkdir -p etc .${ownSpec.stateMount} tmp var/empty
            printf 'root:x:0:0:root:/root:/bin/sh\nsshd:x:74:74:sshd:/var/empty:/bin/sh\ndev:x:1000:1000:Development user:${ownSpec.stateMount}:/bin/sh\n' > etc/passwd
            printf 'root:x:0:\nsshd:x:74:\ndev:x:1000:\n' > etc/group
            touch etc/profile
            chmod 1777 tmp
          '';
          config = ownConfig;
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
        dev-profile = dev.profile;
        dev-image-draft = dev.imageDraft;
      };
      # Fails when the own image or its scripts disagree with hosts/own/spec.json.
      checks.${system}.own-spec = pkgs.runCommand "own-spec-check" {
        nativeBuildInputs = [ pkgs.jq ];
        config = builtins.toJSON ownConfig;
        spec = builtins.toJSON ownSpec;
      } ''
        set -eu
        port=$(jq -r .sshPort <<<"$spec"); mount=$(jq -r .stateMount <<<"$spec")
        jq -e --arg p "$port/tcp" --arg m "$mount" \
          '(.ExposedPorts | has($p)) and (.Volumes | has($m)) and (.Env | index("HOME=" + $m))' <<<"$config"
        grep -qx "Port $port" ${own.sshConfig}
        grep -qF "HostKey $mount/.ssh/" ${own.sshConfig}
        grep -qF "$(jq -r .authorizedKeyEnv <<<"$spec")" ${own.start}/bin/own-start
        grep -qF "$mount/.ssh/authorized_keys" ${own.start}/bin/own-start
        grep -qF "127.0.0.1:$(jq -r .xpraPort <<<"$spec")" ${own.start}/bin/own-start
        grep -qF "$(jq -r .syntheticTrialEnv <<<"$spec")" ${own.browser}
        grep -qF "remote-debugging-port=$(jq -r .cdpPort <<<"$spec")" ${own.browser}
        touch $out
      '';
    };
}
