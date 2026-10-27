#!/usr/bin/env bash
# Build one flake attr for CI. On a step timeout, print an `update-triage:
# timeout-inflight` marker per derivation that started but never finished, so
# update_bot.py triage can attribute the timeout like a build failure.
#
# --single: the attr resolves to one toplevel (a whole host), so `nix build`
# gets there without fetching nix-fast-build's own Nix first.
set -uo pipefail

fast_build=1
if [ "${1:-}" = --single ]; then
  fast_build=
  shift
fi
attr=$1
limit=${BUILD_TIMEOUT:-100m}
log=$(mktemp)

tools=(nixpkgs#coreutils)
if [ -n "$fast_build" ]; then
  tools+=(nixpkgs#nix-fast-build)
  builder=(nix-fast-build --skip-cached --no-nom --no-link --eval-workers 1 --flake "$attr")
else
  builder=(nix build --no-link "$attr")
fi

# nix shell for coreutils: macOS runners have no GNU timeout.
nix shell --inputs-from . "${tools[@]}" --command \
  timeout --signal=INT --kill-after=2m "$limit" \
  "${builder[@]}" 2>&1 | tee "$log"
status=${PIPESTATUS[0]}

if [ "$status" -eq 124 ] || [ "$status" -eq 137 ]; then
  echo "::error::Build exceeded $limit; listing unfinished derivations for triage."
  grep -oE "building '/nix/store/[^']+\.drv'" "$log" | cut -d"'" -f2 | sort -u | while read -r drv; do
    # shellcheck disable=SC2046
    nix-store --check-validity $(nix-store -q --outputs "$drv") 2>/dev/null ||
      echo "update-triage: timeout-inflight $drv"
  done
fi
exit "$status"
