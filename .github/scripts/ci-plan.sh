#!/usr/bin/env bash
# Decide which configurations a commit actually changes, for the build matrix.
#
# A toplevel whose output the cache can already serve was built by an earlier
# run, so there is nothing left to prove about it: the matrix only carries what
# is left. Fails open — anything that can't be evaluated or checked gets built.
#
# ATTIC is the cache URL (e.g. https://attic.example.com/nixos). Outputs:
# `linux` (JSON array of host names) and `darwin` (true/false).
set -uo pipefail

: "${ATTIC:?ATTIC must be the cache URL, e.g. https://attic.example.com/nixos}"

dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT

# phone-vm is aarch64-linux and builds on its own arm runner.
mapfile -t hosts < <(nix eval --json .#nixosConfigurations --apply builtins.attrNames |
  jq -r '.[] | select((startswith("bootstrap") or . == "phone-vm") | not)')
if [ "${#hosts[@]}" -eq 0 ]; then
  echo "::error::no nixosConfigurations to plan; refusing to skip the build"
  exit 1
fi

# One process per host, no eval cache: parallel evals otherwise stall on its SQLite lock.
# shellcheck disable=SC2016 # the substitutions belong to the subshell xargs fills in
printf '%s\n' "${hosts[@]}" | xargs -P 4 -I{} bash -c '
  out=$(nix eval --no-eval-cache --raw ".#nixosConfigurations.$1.config.system.build.toplevel.outPath" 2>/dev/null) || exit 0
  printf "%s\n" "$out" >"$2/$1"
' _ {} "$dir"

build=()
rows=()
for host in "${hosts[@]}"; do
  out=$(cat "$dir/$host" 2>/dev/null)
  reason="evaluating it failed"
  if [ -n "$out" ] && nix path-info --store "$ATTIC" "$out" >/dev/null 2>&1; then
    reason="already in the cache"
  elif [ -n "$out" ]; then
    reason="not in the cache"
  fi
  if [ "$reason" = "already in the cache" ]; then
    rows+=("| $host | no | $reason |")
  else
    build+=("$host")
    rows+=("| $host | yes | $reason |")
  fi
done

darwin=false
mac=$(nix eval --no-eval-cache --raw .#darwinConfigurations.macbook.system.outPath 2>/dev/null)
if [ -n "$mac" ] && nix path-info --store "$ATTIC" "$mac" >/dev/null 2>&1; then
  rows+=("| macbook | no | already in the cache |")
else
  darwin=true
  rows+=("| macbook | yes | not in the cache |")
fi

if [ "${#build[@]}" -eq 0 ]; then
  linux='[]'
else
  linux=$(printf '%s\n' "${build[@]}" | jq -R . | jq -sc .)
fi

{
  echo "### Build plan"
  echo
  echo "| configuration | build | why |"
  echo "| --- | --- | --- |"
  printf '%s\n' "${rows[@]}"
} | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "linux=$linux"
    echo "darwin=$darwin"
  } >>"$GITHUB_OUTPUT"
else
  echo "linux=$linux"
  echo "darwin=$darwin"
fi
