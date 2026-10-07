# windows-dev definitions for Issue #2. Gates 1 and 2 (the exact source of the profile in use and the existing
# owner-auth helper) remain open; this profile is the bounded CI0 bootstrap, not F1 acceptance.
{ pkgs }:
rec {
  # GitHub routing by declared principal, the same outputs own and rent use (hosts/profile/gh.nix): the gh wrapper
  # selects a principal's slot only in a clone bound in its own config, and the profile's git credential helper. Tools
  # binds the Spec clone through the helper's own bind with the Spec's explicit githubPrincipal; Run excludes system and
  # global Git configuration and prompts. The cloneUrl namespace here only names the profile's stable helper; it is not
  # the principal.
  github = import ../../hosts/profile/gh.nix {
    inherit pkgs;
    owner = builtins.head (builtins.match "https://github\\.com/([^/]+)/[^/]+"
      (builtins.fromJSON (builtins.readFile ./spec.json)).cloneUrl);
  };
  ghWrapper = github.wrapper;
  ghCredential = github.helper;

  # Dev-only gh-infra: one immutable upstream release asset. Its GitHub operations still execute the existing gh
  # wrapper from this profile's PATH, so repository-bound principal selection stays owned by hosts/profile/gh.nix.
  ghInfra = pkgs.runCommand "gh-infra-0.14.0" {
    src = pkgs.fetchurl {
      url = "https://github.com/babarot/gh-infra/releases/download/v0.14.0/gh-infra_linux-amd64";
      hash = "sha256-Qw9oo6XnUMLUTSYiNrG2jOCtQUH6RogiYt2rj/0Hoxw=";
    };
  } ''
    install -Dm755 "$src" "$out/bin/gh-infra"
  '';

  # Local real-Jev prerequisite (roccho-dev/adrs#460): three bounded tools over exactly four build-time constants.
  # Only the production instance below is linked into the profile; oci/dev/proof.sh builds a fixture instance of this
  # same source. sops, age and age-keygen are reached by absolute store path inside these closures, never via PATH.
  jevTools =
    {
      envsRemote,
      appsRemote,
      opsRemote,
      identity,
    }:
    let
      q = pkgs.lib.escapeShellArg;
      # One launcher source for both consumers: the same currentness, recipient, build-before-decrypt and child
      # boundary. Each entry adds only its fixed argument parsing, its fixed program and its child's public variables.
      # Every tool before the child reads /dev/null, so the caller's stdin reaches the child untouched.
      mkLaunch =
        {
          name,
          usage,
          parse,
          build,
          say,
          announce,
          childEnv,
        }:
        pkgs.writeShellApplication {
          inherit name;
          text = ''
                set +o xtrace
                ulimit -c 0
                umask 077
                envs_remote=${q envsRemote}
                identity=${q identity}
                cu=${pkgs.coreutils}/bin
                grep=${pkgs.gnugrep}/bin/grep
                cipher_path=ciphertexts/dev-jev-api.oci-dev.sops.yaml
                usage() {
                  echo "usage: ${name} ${usage}" >&2
                  exit 2
                }
                fail() {
                  echo "${name}: RED: $1" >&2
                  exit 1
                }
                say() {
                  echo "${name}: $*" >&${say}
                }
                git_() {
                  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 ${pkgs.git}/bin/git -c credential.helper= "$@" < /dev/null
                }
                nix_() {
                  ${pkgs.nix}/bin/nix --extra-experimental-features 'nix-command flakes' "$@" < /dev/null
                }

            formal=false
            program_args=()
            build_program() {
              ${build}
            }
            ${parse}
            # Artifact-mode refusal occurs before identity/ciphertext access.
            if [ "$formal" = true ]; then build_program; fi
                [ ! -e /homeless-shelter ] || fail "/homeless-shelter exists; the child's HOME must not exist"

                # The ciphertext: at a commit on envs proposals, and exactly the one proposals carries now.
                # The scratch directory holds only public data. Git is pinned to write only the files scratch_clear names (no
                # template, packed objects, no automatic maintenance); they are removed one by one, then the empty
                # directories, on exit and before the child. Anything else is kept and the launch is RED.
                work=$("$cu/mktemp" -d)
                repo=$work/envs.git
                scratch_clear() {
                  [ -e "$work" ] || return 0
                  local f d
                  # Only regular files are removed; a link, FIFO, directory or other type at a known name is kept.
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
                trap 'scratch_clear || echo "${name}: kept $work: unexpected scratch entries" >&2' EXIT
                git_ init -q --bare --template= "$repo"
                git_ -c fetch.unpackLimit=1 -c transfer.unpackLimit=1 -c gc.auto=0 -c maintenance.auto=false \
                  -c fetch.writeCommitGraph=false -C "$repo" fetch -q --no-tags "$envs_remote" \
                  "+refs/heads/proposals:refs/heads/proposals" || fail "cannot fetch envs proposals"
                git_ -C "$repo" cat-file -e "$envs_sha^{commit}" 2>/dev/null || fail "the envs commit is not on proposals"
                git_ -C "$repo" merge-base --is-ancestor "$envs_sha" proposals || fail "the envs commit is not on proposals"
                at=$(git_ -C "$repo" rev-parse -q --verify "$envs_sha:$cipher_path") || fail "no OCI ciphertext at that envs commit"
                now=$(git_ -C "$repo" rev-parse -q --verify "proposals:$cipher_path") || fail "envs proposals has no OCI ciphertext"
                [ "$at" = "$now" ] || fail "that envs commit's OCI ciphertext is not the current one"
                cipher=$work/cipher.yaml
                git_ -C "$repo" cat-file blob "$at" > "$cipher"
                fields=$("$grep" -E '^[^[:space:]#][^:]*:' "$cipher" | "$cu/cut" -d: -f1 | "$cu/sort" | "$cu/tr" '\n' ' ')
                [ "$fields" = "JEV_API_KEY sops " ] || fail "the ciphertext fields differ"
                "$grep" -q '^JEV_API_KEY: ENC\[AES256_GCM,' "$cipher" || fail "the ciphertext is not SOPS-encrypted"
                recipients=$("$grep" -E '^[[:space:]]*-?[[:space:]]*recipient:[[:space:]]*age1[0-9a-z]+[[:space:]]*$' "$cipher" \
                  | "$grep" -oE 'age1[0-9a-z]+' || true)
                { [ -n "$recipients" ] && [ "$(echo "$recipients" | "$cu/wc" -l)" -eq 1 ]; } \
                  || fail "the ciphertext must have exactly one recipient"

                # The identity: a regular 0600 file of this user whose recipient is the ciphertext's.
                { [ -f "$identity" ] && [ ! -L "$identity" ]; } || fail "the target identity is missing"
                [ "$("$cu/stat" -c %a "$identity")" = 600 ] || fail "the target identity must have mode 0600"
                [ "$("$cu/stat" -c %u "$identity")" = "$("$cu/id" -u)" ] || fail "the target identity must belong to this user"
                own=$(${pkgs.age}/bin/age-keygen -y "$identity" 2>/dev/null < /dev/null) || fail "the target identity is unreadable"
                [ "$own" = "$recipients" ] || fail "the ciphertext is not for this target identity"

                # The exact consumer program, evaluated and realized before anything is decrypted.
            if [ "$formal" = false ]; then build_program; fi
                say "built $program"

                say "decrypt envs $envs_sha ciphertext $at recipient $recipients"
                key=$(SOPS_AGE_KEY_FILE=$identity ${pkgs.sops}/bin/sops --decrypt --input-type yaml --extract '["JEV_API_KEY"]' \
                  "$cipher" 2>/dev/null < /dev/null) || fail "decryption failed"
                [ -n "$key" ] || fail "the decrypted key is empty"
                { [ "''${#key}" -le 4096 ] && [[ $key != *$'\n'* ]]; } || fail "the decrypted key is not one short line"
                scratch_clear || fail "kept $work: unexpected scratch entries"
                trap - EXIT

                # One foreground child whose environment is built from nothing (env -i). The key reaches it only on
                # descriptor 3, a here-string that bash passes as a pipe because the key is one short line (never a file,
                # argv or stdin). At that fixed boundary the child reads the key, then closes every descriptor above 2 that is
                # still open (the key pipe and anything the caller left open; bash -c has no script descriptor of its own) and
                # becomes the program, so only stdin, stdout and stderr, the exit status and signals are the program's own.
                say "${announce}"
                # shellcheck disable=SC2016
                exec "$cu/env" -i PATH="$cu" HOME=/homeless-shelter LANG=C.UTF-8 ${childEnv} \
                  ${pkgs.bash}/bin/bash -c 'IFS= read -r -u 3 JEV_API_KEY || true
                    for f in /proc/$$/fd/*; do
                      n=''${f##*/}
                      if [[ $n =~ ^[0-9]+$ ]] && [ "$n" -gt 2 ] && [ -e "$f" ]; then exec {n}<&-; fi
                    done
                    unset f n; export JEV_API_KEY; exec env -u PWD -u SHLVL -u OLDPWD -- "$0" "$@"' \
                  "$program" "''${program_args[@]}" 3<<< "$key"
          '';
        };
    in
    {
      # Creates the target identity once: fixed path, safe parent, exclusive create, public recipient output only.
      init = pkgs.writeShellApplication {
        name = "jev-age-init";
        text = ''
          set +o xtrace
          umask 077
          identity=${q identity}
          cu=${pkgs.coreutils}/bin
          fail() {
            echo "jev-age-init: RED: $1" >&2
            exit 1
          }
          [ "$#" -eq 0 ] || fail "takes no arguments"
          { [ ! -e "$identity" ] && [ ! -L "$identity" ]; } || fail "the target identity exists and is never overwritten"
          dir=$("$cu/dirname" "$identity")
          "$cu/mkdir" -p "$dir"
          { [ -d "$dir" ] && [ ! -L "$dir" ]; } || fail "the identity directory is not a real directory"
          [ "$("$cu/stat" -c %u "$dir")" = "$("$cu/id" -u)" ] || fail "the identity directory is not owned by this user"
          [ $(( 8#$("$cu/stat" -c %a "$dir") & 8#022 )) -eq 0 ] || fail "the identity directory is writable by others"
          tmp=$("$cu/mktemp" "$dir/.identity.XXXXXX")
          trap '"$cu/rm" -f "$tmp"' EXIT
          ${pkgs.age}/bin/age-keygen 2>/dev/null > "$tmp" || fail "age-keygen failed"
          # A hard link is created atomically and never replaces an existing file.
          "$cu/ln" -T "$tmp" "$identity" 2>/dev/null || fail "the target identity exists and is never overwritten"
          ${pkgs.age}/bin/age-keygen -y "$identity"
        '';
      };
      # Starts the exact apps dev server in the foreground with JEV_API_KEY as the only secret in its environment.
      launch = mkLaunch {
        name = "voice-ui-jev-dev";
        usage = "--envs-sha <40-hex> --apps-sha <40-hex> --port <1024-65535> [--host 127.0.0.1|0.0.0.0] | --formal --envs-sha <40-hex> --deploy-sha <40-hex> --deploy-provenance-sha256 <64-hex> --deploy-proof-sha256 <64-hex> --artifacts <absolute-dir> --port <1024-65535> [--host 127.0.0.1|0.0.0.0] [--post-limit <1-12>]";
        say = "1";
        announce = "apps $apps_sha on $host:$port with PATH HOME LANG PORT HOST JEV_API_KEY";
        childEnv = ''PORT="$port" HOST="$host"'';
        parse = ''
          apps_remote=${q appsRemote}
          formal=false
          if [ "''${1:-}" = --formal ]; then formal=true; shift; fi
          envs_sha="" apps_sha="" port="" host=""
          deploy_sha="" deploy_provenance="" deploy_proof="" artifacts="" post_limit=""
          if [ "$formal" = true ]; then
            { [ "$#" -eq 12 ] || [ "$#" -eq 14 ] || [ "$#" -eq 16 ]; } || usage
          else
            { [ "$#" -eq 6 ] || [ "$#" -eq 8 ]; } || usage
          fi
          while [ "$#" -gt 0 ]; do
            { [ "$formal" = false ] || [ -n "''${2:-}" ]; } || usage
            case "$1" in
              --envs-sha) [ -z "$envs_sha" ] || usage; envs_sha=$2 ;;
              --apps-sha) { [ "$formal" = false ] && [ -z "$apps_sha" ]; } || usage; apps_sha=$2 ;;
              --deploy-sha) { [ "$formal" = true ] && [ -z "$deploy_sha" ]; } || usage; deploy_sha=$2 ;;
              --deploy-provenance-sha256) { [ "$formal" = true ] && [ -z "$deploy_provenance" ]; } || usage; deploy_provenance=$2 ;;
              --deploy-proof-sha256) { [ "$formal" = true ] && [ -z "$deploy_proof" ]; } || usage; deploy_proof=$2 ;;
              --post-limit) { [ "$formal" = true ] && [ -z "$post_limit" ]; } || usage; post_limit=$2 ;;
            --artifacts) { [ "$formal" = true ] && [ -z "$artifacts" ]; } || usage; artifacts=$2 ;;
              --port) [ -z "$port" ] || usage; port=$2 ;;
              --host) { [ -z "$host" ] && [ -n "$2" ]; } || usage; host=$2 ;;
              *) usage ;;
            esac
            shift 2
          done
          [[ $envs_sha =~ ^[0-9a-f]{40}$ && $port =~ ^[1-9][0-9]{3,4}$ ]] || usage
          if [ "$formal" = true ]; then
            { [ -z "$post_limit" ] || [[ $post_limit =~ ^([1-9]|1[0-2])$ ]]; } || usage
          [[ $deploy_sha =~ ^[0-9a-f]{40}$ && $deploy_provenance =~ ^[0-9a-f]{64}$ && $deploy_proof =~ ^[0-9a-f]{64}$ && $artifacts = /* ]] || usage
          else
            [[ $apps_sha =~ ^[0-9a-f]{40}$ ]] || usage
          fi
          { [ "$port" -ge 1024 ] && [ "$port" -le 65535 ]; } || usage
          [ -n "$host" ] || host=127.0.0.1
          case $host in 127.0.0.1 | 0.0.0.0) ;; *) usage ;; esac
        '';
        build = ''
            if [ "$formal" = true ]; then
              # Approved public expectations bind the DEPLOY operand before import.
              # Bootstrap only: the secret child cannot build, import or decrypt.
            prepared=$(${pkgs.coreutils}/bin/env -u NODE_OPTIONS -u NODE_EXTRA_CA_CERTS ${pkgs.nodejs}/bin/node --input-type=module - "$artifacts" "$deploy_sha" "$deploy_provenance" "$deploy_proof" <<'JS'
              import fs from 'node:fs';
              import path from 'node:path';
            import crypto from 'node:crypto';
            import assert from 'node:assert/strict';
              import { execFileSync } from 'node:child_process';
              import { pathToFileURL } from 'node:url';
              const [directory, sha, provenanceHash, proofHash] = process.argv.slice(2);
              const require = value => { if (!value) throw Error('formal_admission'); };
              const file = p => { require(fs.lstatSync(p).isFile()); return fs.readFileSync(p); };
              const hash = p => {
                require(fs.lstatSync(p).isFile());
                const fd = fs.openSync(p, 'r'), digest = crypto.createHash('sha256'), chunk = Buffer.alloc(1024 * 1024);
                try { for (let n; (n = fs.readSync(fd, chunk, 0, chunk.length, null)) > 0;) digest.update(chunk.subarray(0, n)); }
                finally { fs.closeSync(fd); }
                return digest.digest('hex');
              };
              const importArchive = p => {
                const fd = fs.openSync(p, 'r');
                try { execFileSync(store, ['--import'], {env:{},stdio:[fd,'ignore','ignore']}); }
                finally { fs.closeSync(fd); }
              };
              const json = p => JSON.parse(file(p));
              const nix = '${pkgs.nix}/bin/nix', store = '${pkgs.nix}/bin/nix-store';
              const canonical = rows => JSON.stringify(rows.map(({path,narHash,narSize}) => ({path,narHash,narSize})).sort((a,b)=>a.path.localeCompare(b.path)));
              const closure = (root, rows) => {
                const info = JSON.parse(execFileSync(nix, ['--extra-experimental-features','nix-command flakes','path-info','--json','--recursive',root], {env:{},stdio:['ignore','pipe','ignore']}));
                const actual = Array.isArray(info) ? info : Object.entries(info).map(([path,row])=>({...row,path}));
              require(Array.isArray(rows) && canonical(actual) === canonical(rows));
              execFileSync(store, ['--verify-path', ...actual.map(row => row.path)], {env:{},stdio:['ignore','ignore','ignore']});
              };
            let stage='deploy_operand';
            try {
                const deploy = path.join(directory,'deploy');
                require(JSON.stringify(fs.readdirSync(deploy).sort()) === JSON.stringify(['merged-pr-proof.json','provenance.json','voice-ui-target-runtime.nix-export','voice-ui-target-runtime.nix-export.sha256']));
              stage='deploy_provenance'; require(hash(path.join(deploy,'provenance.json')) === provenanceHash);
              stage='deploy_proof'; require(hash(path.join(deploy,'merged-pr-proof.json')) === proofHash);
                const p = json(path.join(deploy,'provenance.json')), q = json(path.join(deploy,'merged-pr-proof.json'));
                require(p.schema === 'roccho.voice-ui-target-runtime.release-provenance/1' && p.source.repository === 'roccho-dev/ops' && p.source.commit === sha);
                require(q.merge_sha === sha && q.base === 'proposals' && q.reviewed_tree === q.merge_tree && q.merge_tree === p.source.tree && q.merged_at);
                require(Number.isSafeInteger(q.pr_number) && q.r_exact_head_verdict_ref.startsWith('https://github.com/roccho-dev/ops/pull/'+q.pr_number+'#pullrequestreview-'));
              stage='deploy_export';
              const exp = path.join(deploy,'voice-ui-target-runtime.nix-export');
                require(p.deploy.name === 'voice-ui-target-runtime.nix-export' && p.deploy.format === 'nix-store --export' && hash(exp) === p.deploy.sha256 && fs.statSync(exp).size === p.deploy.bytes);
              require(new RegExp('^/nix/store/[0-9a-z]{32}-voice-ui-target-runtime$').test(p.deploy.root) && p.deploy.entry === p.deploy.root+'/bin/voice-ui-target-runtime');
                require(p.deploy.locator === 'https://github.com/roccho-dev/ops/releases/download/voice-ui-target-runtime-'+sha+'/voice-ui-target-runtime.nix-export');
                require(file(exp+'.sha256').toString() === p.deploy.sha256+'  voice-ui-target-runtime.nix-export\n');
                importArchive(exp);
              stage='deploy_closure'; closure(p.deploy.root,p.deploy.closure);
              stage='deploy_configuration';
                const runtime = p.deploy.root+'/share/voice-ui-target-runtime';
                const config = json(runtime+'/configuration.json');
              require(config.opsSha === sha); assert.deepEqual(config.product,p.apps_pin);
                const { admitProduct } = await import(pathToFileURL(runtime+'/modules/input-contracts.mjs'));
                const workdir = fs.mkdtempSync('/tmp/voice-ui-formal-');
              stage='product_admission';
              const admitted = admitProduct({directory:path.join(directory,'product'),pin:config.product,unzip:config.unzip,workdir});
                const a = json(path.join(directory,'product/provenance.json')).acceptance;
              stage='acceptance_export';
              const acceptance = path.join(directory,'voice-ui-acceptance-runtime.nix-export');
                require(hash(acceptance) === a.sha256 && fs.statSync(acceptance).size === a.bytes);
              require(new RegExp('^/nix/store/[0-9a-z]{32}-voice-ui-acceptance-node$').test(a.root) && a.entry === a.root+'/bin/voice-ui-acceptance-node');
                importArchive(acceptance);
              stage='acceptance_closure'; closure(a.root,a.closure);
              stage='formal_entry';
                require(fs.statSync(a.entry).mode & 0o111);
                require(admitted.manifest.e2e.local_serve_entrypoint === 'e2e/serve.mjs' && admitted.manifest.files.some(row=>row.path === 'e2e/serve.mjs'));
              console.log(a.entry); console.log(admitted.root+'/e2e/serve.mjs'); console.log(config.product.proof.merge_sha);
            } catch { console.error('voice-ui-jev-dev: RED: formal_admission_'+stage); process.exitCode=1; }
          JS
              ) || fail "formal admission failed"
              mapfile -t entries <<< "$prepared"
            [ "''${#entries[@]}" -eq 3 ] || fail "formal entry set differs"
              program=''${entries[0]}
              program_args=("''${entries[1]}" --formal)
            if [ -n "$post_limit" ]; then
              # Fixed measurement only; no caller-selected module/code or answer fixture.
              preload="data:text/javascript,const%20native%3DglobalThis.fetch.bind(globalThis)%3Blet%20sent%3D0%3BglobalThis.fetch%3D(input%2Cinit%3D%7B%7D)%3D%3E%7Bconst%20url%3Dtypeof%20input%3D%3D%3D'string'%3Finput%3Ainput.url%3Bconst%20method%3Dinit.method%3F%3Finput.method%3F%3F'GET'%3Bif(url!%3D%3D'https%3A%2F%2Fapi.typesafe.ai%2Fv1%2Fsystemone'%7C%7Cmethod!%3D%3D'POST')return%20Promise.reject(Error('upstream_boundary'))%3Bif(sent%3E%3D__LIMIT__)return%20Promise.reject(Error('upstream_budget'))%3Bsent%2B%2B%3Bprocess.stderr.write('jev-upstream-send%3A'%2Bsent%2B'%5Cn')%3Breturn%20native(input%2C%7B...init%2Credirect%3A'error'%7D)%3B%7D%3B"
              preload=''${preload/__LIMIT__/$post_limit}
              program_args=(--import "$preload" "''${program_args[@]}")
            fi
            apps_sha=''${entries[2]}
            else
            ref="git+$apps_remote?rev=$apps_sha"
            program=$(nix_ eval --raw "$ref#apps.x86_64-linux.dev.program") || fail "cannot evaluate the apps dev program"
            drv=$(nix_ eval --raw "$ref#apps.x86_64-linux.dev.program" --apply \
              'p: let c = builtins.attrNames (builtins.getContext p); in if builtins.length c == 1 then builtins.head c else throw "not one derivation"') \
              || fail "the apps dev program is not one derivation"
            outs=$(nix_ build --no-link --print-out-paths "$drv^*") || fail "cannot build the apps dev program"
            built=""
            while read -r out; do
              case "$program" in "$out" | "$out"/*) built=$out ;; esac
            done <<< "$outs"
            { [ -n "$built" ] && [ -x "$program" ]; } || fail "the built program is not the evaluated one"
            fi
        '';
      };
      # Runs the exact ops Jev CLI once: the caller's stdin is its request, its single stdout line is the result, and
      # the launcher's own messages go to stderr. Only the fixed package output; no attribute, program or argument choice.
      ops = mkLaunch {
        name = "ops-jev";
        usage = "--envs-sha <40-hex> --ops-sha <40-hex>";
        say = "2";
        announce = "ops $ops_sha jev with PATH HOME LANG JEV_API_KEY";
        childEnv = "";
        parse = ''
          ops_remote=${q opsRemote}
          envs_sha="" ops_sha=""
          [ "$#" -eq 4 ] || usage
          while [ "$#" -gt 0 ]; do
            case "$1" in
              --envs-sha) [ -z "$envs_sha" ] || usage; envs_sha=$2 ;;
              --ops-sha) [ -z "$ops_sha" ] || usage; ops_sha=$2 ;;
              *) usage ;;
            esac
            shift 2
          done
          [[ $envs_sha =~ ^[0-9a-f]{40}$ && $ops_sha =~ ^[0-9a-f]{40}$ ]] || usage
        '';
        build = ''
          out=$(nix_ build --no-link --print-out-paths "git+$ops_remote?rev=$ops_sha#packages.x86_64-linux.jev") \
            || fail "cannot build the ops jev package"
          [ "$(printf '%s\n' "$out" | "$cu/wc" -l)" -eq 1 ] || fail "the ops jev package is not one output"
          program=$out/bin/jev
          { [ -f "$program" ] && [ -x "$program" ]; } || fail "the ops jev package has no bin/jev"
        '';
      };
    };
  jev = jevTools {
    envsRemote = "https://github.com/roccho-dev/envs";
    appsRemote = "https://github.com/roccho-dev/apps";
    opsRemote = "https://github.com/roccho-dev/ops";
    identity = "/work/repos/.auth/roccho-dev/age/oci-dev.key";
  };

  pi = import ./pi.nix {
    inherit pkgs;
    envsRemote = "https://github.com/roccho-org/envs";
    identity = "/work/repos/.auth/roccho-dev/age/oci-dev.key";
    agentDir = "/home/dev/.pi/agent-oci-dev";
  };

  # The tools that the Tools step realizes into /nix/var/nix/profiles/windows-dev.
  profile = pkgs.buildEnv {
    name = "windows-dev";
    paths =
      (with pkgs; [
        bash
        coreutils
        git
        cacert
        openssh
      ])
      ++ [
        ghInfra
        ghWrapper
        ghCredential
        jev.init
        jev.launch
        jev.ops
        pi.launcher
      ];
    pathsToLink = [
      "/bin"
      "/etc/ssl"
    ];
  };

  # A trusted, single-user development image, not an own/rent runtime image.
  # Nix's database AND closure are seeded together by the existing Init pattern:
  # run this exact image with the empty nix volume at /seed, copy /nix/., then
  # mount that volume at /nix for use. Recreate with the same image identity.
  # A different image uses a fresh nix cache; retain work and the old cache for rollback.
  image = pkgs.dockerTools.buildLayeredImage {
    name = "ghcr.io/roccho-dev/windows-dev";
    tag = "nix";
    contents = [
      profile
      pkgs.nix
      pkgs.curl
    ];
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
      Cmd = [
        "/bin/bash"
        "--login"
      ];
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
