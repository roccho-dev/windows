#!/usr/bin/env bash
# Read only the selected rent Tool generation. This is an observation, never an adoption or update.
# Run inside the already-authorized rent container; the caller proves the Host/container identity.
# No nix-store query, daemon, network, secret read, write, profile repair or implicit rollback.
set -euo pipefail
unknown() { echo "rent-selection: UNKNOWN ($1)" >&2; exit 2; }
[ "$#" -eq 0 ] || unknown "arguments forbidden"
[ -r /proc/self/mountinfo ] || unknown "mount evidence unavailable"
count=0
while read -r _id _parent _dev root mp opts _rest; do
  [ "$mp" = /nix ] || continue
  count=$((count + 1))
  case "$root" in */volumes/*/_data) ;; *) unknown "foreign nix mount" ;; esac
  case ",$opts," in *,rw,*|*,ro,*) ;; *) unknown "nix mount mode unavailable" ;; esac
done < /proc/self/mountinfo
[ "$count" -eq 1 ] || unknown "nix mount ambiguous"
[ "$(cat /nix/var/rent-nix 2>/dev/null || true)" = "windows-rent-nix v1" ] ||
  unknown "rent volume marker absent or foreign"

dir=/nix/var/nix/profiles
for p in /nix/var /nix/var/nix "$dir"; do
  [ ! -L "$p" ] || unknown "profile parent symlink"
  if [ -e "$p" ]; then
    [ -d "$p" ] && [ "$(stat -c %u "$p")" = 0 ] || unknown "profile parent owner/type"
    # Identical permission invariant to B-only flake.nix profileCheck: not writable by group/other.
    mode=$(stat -c %a "$p") || unknown "profile parent mode unreadable"
    [[ $mode =~ ^[0-7]{3,4}$ ]] || unknown "profile parent mode invalid"
    (( (8#$mode & 0022) == 0 )) || unknown "profile parent writable by group/other"
  fi
done
for p in "$dir"/.rent-dev*; do
  [ ! -e "$p" ] && [ ! -L "$p" ] || unknown "interrupted profile selector"
done
selected="$dir/rent-dev"
if [ ! -e "$selected" ] && [ ! -L "$selected" ]; then
  for p in "$dir"/rent-dev-*; do
    [ ! -e "$p" ] && [ ! -L "$p" ] || unknown "orphan generation"
  done
  printf 'selection=ABSENT proof=geometry-only\n'
  exit 0
fi
[ -L "$selected" ] && [ "$(stat -c %u "$selected")" = 0 ] ||
  unknown "selected profile is not a root-owned link"
generation=$(readlink "$selected") || unknown "selected link unreadable"
[[ $generation =~ ^rent-dev-[1-9][0-9]*-link$ ]] ||
  unknown "selected link has unsupported shape"
[ -d "$dir" ] && [ "$(stat -c %u "$dir")" = 0 ] ||
  unknown "profile directory not root-owned"
core=$(readlink -e /bin/git-credential-github-roccho-dev) ||
  unknown "fixed Core helper unavailable"
found=0
target=
for g in "$dir"/rent-dev-*; do
  [ -L "$g" ] && [ "$(stat -c %u "$g")" = 0 ] ||
    unknown "generation is not a root-owned link"
  [[ ${g##*/} =~ ^rent-dev-[1-9][0-9]*-link$ ]] ||
    unknown "unsupported generation name"
  path=$(readlink "$g") || unknown "generation target unreadable"
  [[ $path =~ ^/nix/store/[0-9a-z]{32}-[^/]+$ ]] &&
    [ -d "$path" ] || unknown "generation target missing or foreign"
  helper=$(readlink -e "$path/bin/git-credential-github-roccho-dev") ||
    unknown "generation helper missing"
  [ "$helper" = "$core" ] || unknown "generation Core helper mismatch"
  if [ "${g##*/}" = "$generation" ]; then
    found=1
    target=$path
  fi
done
[ "$found" -eq 1 ] || unknown "selected generation missing"
[ "$(readlink "$selected")" = "$generation" ] &&
  [ "$(readlink "$dir/$generation")" = "$target" ] ||
  unknown "selected links changed during read"
# This proves link geometry and a stable helper reference only, not store byte integrity,
# quietness, authorization, installed CLI validity, desired D, or completed effect E.
printf 'selection=SELECTED generation=%s store=%s proof=geometry-only\n' "$generation" "$target"
