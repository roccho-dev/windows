{ pkgs
, envsRemote ? "https://github.com/roccho-org/envs"
, identity ? "/work/repos/.auth/roccho-dev/age/oci-dev.key"
, agentDir ? "/home/dev/.pi/agent-oci-dev"
}:
let
  version = "1.0.4";
  bindingId = "opencode-go.oci-dev";

  upstream = pkgs.stdenvNoCC.mkDerivation {
    pname = "pi";
    inherit version;

    src = pkgs.fetchurl {
      url = "https://github.com/earendil-works/pi/releases/download/v${version}/pi-linux-x64.tar.gz";
      hash = "sha256-KExF3SjPl1oTz/avNHQd0KDNymY06L38AIOufUUuhtY=";
    };

    nativeBuildInputs = [ pkgs.autoPatchelfHook ];
    buildInputs = [ pkgs.stdenv.cc.cc.lib ];

    sourceRoot = ".";
    unpackPhase = ''
      runHook preUnpack
      tar -xzf "$src"
      runHook postUnpack
    '';

    installPhase = ''
      runHook preInstall
      test -x pi/pi
      mkdir -p "$out/bin" "$out/share/pi"
      cp -R pi/. "$out/share/pi/"
      ln -s "$out/share/pi/pi" "$out/bin/pi-upstream"
      runHook postInstall
    '';
  };

  resolver = pkgs.writeShellApplication {
    name = "pi-opencode-go-key";
    text = ''
      set +o xtrace
      ulimit -c 0
      umask 077

      remote=${pkgs.lib.escapeShellArg envsRemote}
      identity=${pkgs.lib.escapeShellArg identity}
      binding=${pkgs.lib.escapeShellArg bindingId}
      cu=${pkgs.coreutils}/bin
      git=${pkgs.git}/bin/git
      jq=${pkgs.jq}/bin/jq
      grep=${pkgs.gnugrep}/bin/grep

      fail() {
        echo "pi-opencode-go-key: RED: $1" >&2
        exit 1
      }
      [ "$#" -eq 2 ] && [ "$1" = --envs-sha ] || fail "usage: --envs-sha <40-hex>"
      envs_sha=$2
      [[ $envs_sha =~ ^[0-9a-f]{40}$ ]] || fail "invalid envs revision"

      work=$("$cu/mktemp" -d)
      repo=$work/envs.git
      scratch_clear() {
        [ -e "$work" ] || return 0
        local f d
        for f in "$repo"/objects/pack/*; do
          [[ ''${f##*/} =~ ^pack-[0-9a-f]{40}([0-9a-f]{24})?\.(pack|idx|rev)$ ]] || continue
          if [ -L "$f" ] || [ ! -f "$f" ]; then return 1; fi
          "$cu/rm" -f -- "$f"
        done
        for f in "$work/cipher.yaml" "$repo/HEAD" "$repo/config" "$repo/FETCH_HEAD" "$repo/packed-refs" \
          "$repo/refs/heads/proposals"; do
          if [ -L "$f" ] || { [ -e "$f" ] && [ ! -f "$f" ]; }; then return 1; fi
          "$cu/rm" -f -- "$f"
        done
        for d in "$repo/objects/pack" "$repo/objects/info" "$repo/objects" "$repo/refs/heads" "$repo/refs/tags" \
          "$repo/refs" "$repo" "$work"; do
          [ ! -e "$d" ] || "$cu/rmdir" -- "$d" 2>/dev/null || return 1
        done
      }
      trap 'scratch_clear || echo "pi-opencode-go-key: kept $work: unexpected scratch entries" >&2' EXIT

      git_() {
        "$cu/env" -i \
          HOME=/homeless-shelter \
          GIT_CONFIG_NOSYSTEM=1 \
          GIT_CONFIG_GLOBAL=/dev/null \
          GIT_TERMINAL_PROMPT=0 \
          GIT_SSL_CAINFO=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt \
          "$git" -c credential.helper= "$@" < /dev/null
      }

      git_ init -q --bare --template= "$repo"
      git_ -c fetch.unpackLimit=1 -c transfer.unpackLimit=1 -c gc.auto=0 -c maintenance.auto=false \
        -c fetch.writeCommitGraph=false -C "$repo" fetch -q --no-tags "$remote" \
        "+refs/heads/proposals:refs/heads/proposals" || fail "cannot fetch envs proposals"
      git_ -C "$repo" cat-file -e "$envs_sha^{commit}" 2>/dev/null || fail "envs revision is absent"
      git_ -C "$repo" merge-base --is-ancestor "$envs_sha" proposals || fail "envs revision is not on proposals"

      binding_at=$(git_ -C "$repo" show "$envs_sha:contracts/bindings.jsonl" \
        | "$jq" -csS --arg id "$binding" "[.[] | select(.id == \$id)] | if length == 1 then .[0] else error(\"binding\") end" 2>/dev/null) \
        || fail "binding is absent at envs revision"
      binding_now=$(git_ -C "$repo" show "proposals:contracts/bindings.jsonl" \
        | "$jq" -csS --arg id "$binding" "[.[] | select(.id == \$id)] | if length == 1 then .[0] else error(\"binding\") end" 2>/dev/null) \
        || fail "binding is absent on current proposals"
      [ "$binding_at" = "$binding_now" ] || fail "binding changed after envs revision"

      printf '%s\n' "$binding_at" | "$jq" -e --arg id "$binding" "
        .id == \$id
        and .kind == \"envs.authCapability.v1\"
        and .capability == \"opencode-go\"
        and .source_key == \"OPENCODE_API_KEY\"
        and .target == {\"repository\":\"roccho-dev/windows\",\"host\":\"oci-dev\",\"kind\":\"pi_auth_command\"}
        and (.ciphertext | type == \"string\")
      " >/dev/null || fail "binding meaning differs"

      cipher_path=$(printf '%s\n' "$binding_at" | "$jq" -er '.ciphertext')
      [[ $cipher_path =~ ^ciphertexts/[A-Za-z0-9._-]+[.]sops[.]ya?ml$ ]] || fail "ciphertext path differs"
      at=$(git_ -C "$repo" rev-parse -q --verify "$envs_sha:$cipher_path") || fail "ciphertext is absent at envs revision"
      now=$(git_ -C "$repo" rev-parse -q --verify "proposals:$cipher_path") || fail "ciphertext is absent on current proposals"
      [ "$at" = "$now" ] || fail "ciphertext changed after envs revision"

      cipher=$work/cipher.yaml
      git_ -C "$repo" cat-file blob "$at" > "$cipher"
      fields=$("$grep" -E '^[^[:space:]#][^:]*:' "$cipher" | "$cu/cut" -d: -f1 | "$cu/sort" | "$cu/tr" '\n' ' ')
      [ "$fields" = "OPENCODE_API_KEY sops " ] || fail "ciphertext fields differ"
      "$grep" -q '^OPENCODE_API_KEY: ENC\[AES256_GCM,' "$cipher" || fail "credential is not SOPS encrypted"
      recipients=$("$grep" -E '^[[:space:]]*-?[[:space:]]*recipient:[[:space:]]*age1[0-9a-z]+[[:space:]]*$' "$cipher" \
        | "$grep" -oE 'age1[0-9a-z]+' || true)
      { [ -n "$recipients" ] && [ "$(printf '%s\n' "$recipients" | "$cu/wc" -l)" -eq 1 ]; } \
        || fail "ciphertext must have one recipient"

      { [ -f "$identity" ] && [ ! -L "$identity" ]; } || fail "target identity is missing"
      [ "$("$cu/stat" -c %a "$identity")" = 600 ] || fail "target identity mode differs"
      [ "$("$cu/stat" -c %u "$identity")" = "$("$cu/id" -u)" ] || fail "target identity owner differs"
      own=$(${pkgs.age}/bin/age-keygen -y "$identity" 2>/dev/null < /dev/null) || fail "target identity is unreadable"
      [ "$own" = "$recipients" ] || fail "ciphertext recipient differs from target identity"

      key=$(SOPS_AGE_KEY_FILE="$identity" ${pkgs.sops}/bin/sops \
        --decrypt --input-type yaml --extract '["OPENCODE_API_KEY"]' "$cipher" 2>/dev/null < /dev/null) \
        || fail "credential decryption failed"
      [ -n "$key" ] || fail "credential is empty"
      [ "$(printf %s "$key" | "$cu/wc" -c)" -le 4096 ] || fail "credential is too large"
      [[ $key != *$'\n'* ]] || fail "credential is not one line"

      scratch_clear || fail "kept scratch with unexpected entries"
      trap - EXIT
      printf '%s\n' "$key"
    '';
  };

  launcher = pkgs.writeShellApplication {
    name = "pi";
    text = ''
      set +o xtrace
      ulimit -c 0
      umask 077

      agent_dir=${pkgs.lib.escapeShellArg agentDir}
      cu=${pkgs.coreutils}/bin
      resolver=${resolver}/bin/pi-opencode-go-key
      upstream=${upstream}/bin/pi-upstream
      package_dir=${upstream}/share/pi

      fail() {
        echo "pi: RED: $1" >&2
        exit 1
      }

      case "''${1:-}" in
        -h|--help|-v|--version)
          export PI_CODING_AGENT_DIR="$agent_dir" PI_PACKAGE_DIR="$package_dir"
          unset OPENCODE_API_KEY
          exec "$upstream" "$@"
          ;;
      esac

      [ "$#" -ge 2 ] && [ "$1" = --envs-sha ] || fail "usage: pi --envs-sha <40-hex> [pi args...]"
      envs_sha=$2
      shift 2
      [[ $envs_sha =~ ^[0-9a-f]{40}$ ]] || fail "invalid envs revision"

      if [ -L "$agent_dir" ] || { [ -e "$agent_dir" ] && [ ! -d "$agent_dir" ]; }; then
        fail "agent directory is not a real directory"
      fi
      "$cu/mkdir" -p "$agent_dir"
      [ "$("$cu/stat" -c %a "$agent_dir")" = 700 ] || fail "agent directory mode differs"
      [ "$("$cu/stat" -c %u "$agent_dir")" = "$("$cu/id" -u)" ] || fail "agent directory owner differs"

      models="$agent_dir/models.json"
      [ ! -e "$models" ] && [ ! -L "$models" ] || fail "models.json would override native providers"

      auth="$agent_dir/auth.json"
      expected=$(printf '{"opencode-go":{"type":"api_key","key":"!%s --envs-sha %s"}}\n' "$resolver" "$envs_sha")
      tmp=$("$cu/mktemp" "$agent_dir/.auth.XXXXXXXX")
      cleanup() { "$cu/rm" -f -- "$tmp"; }
      trap cleanup EXIT
      printf '%s' "$expected" > "$tmp"
      "$cu/chmod" 600 "$tmp"

      if [ ! -e "$auth" ] && [ ! -L "$auth" ]; then
        "$cu/ln" -T "$tmp" "$auth" 2>/dev/null || true
      fi
      { [ -f "$auth" ] && [ ! -L "$auth" ]; } || fail "auth.json is not a regular file"
      [ "$("$cu/stat" -c %a "$auth")" = 600 ] || fail "auth.json mode differs"
      [ "$("$cu/stat" -c %u "$auth")" = "$("$cu/id" -u)" ] || fail "auth.json owner differs"
      printf '%s' "$expected" | "$cu/cmp" -s - "$auth" || fail "auth.json conflicts with canonical Go command"
      cleanup
      trap - EXIT

      export PI_CODING_AGENT_DIR="$agent_dir" PI_PACKAGE_DIR="$package_dir"
      unset OPENCODE_API_KEY
      exec "$upstream" "$@"
    '';
  };

  fixtureTools = pkgs.buildEnv {
    name = "pi-opencode-go-fixture-tools";
    paths = [ pkgs.age pkgs.sops pkgs.git pkgs.jq pkgs.coreutils ];
    pathsToLink = [ "/bin" ];
  };
in
{
  inherit version upstream resolver launcher fixtureTools;
}
