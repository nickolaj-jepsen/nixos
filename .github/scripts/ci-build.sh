#!/usr/bin/env bash
# Build one flake attr for CI. On a step timeout, print an `update-triage:
# timeout-inflight` marker per derivation that started but never finished, so
# update_bot.py triage can attribute the timeout like a build failure.
set -uo pipefail

attr=$1
limit=${BUILD_TIMEOUT:-100m}
log=$(mktemp)

# nix shell for coreutils: macOS runners have no GNU timeout.
nix shell --inputs-from . nixpkgs#coreutils nixpkgs#nix-fast-build --command \
  timeout --signal=INT --kill-after=2m "$limit" \
  nix-fast-build --skip-cached --no-nom --no-link --eval-workers 1 --flake "$attr" 2>&1 | tee "$log"
status=${PIPESTATUS[0]}

if [ "$status" -eq 124 ] || [ "$status" -eq 137 ]; then
  echo "::error::Build exceeded $limit; listing unfinished derivations for triage."
  grep -oE "building '/nix/store/[^']+\.drv'" "$log" | cut -d"'" -f2 | sort -u | while read -r drv; do
    # shellcheck disable=SC2046
    nix-store --check-validity $(nix-store -q --outputs "$drv") 2>/dev/null ||
      echo "update-triage: timeout-inflight $drv"
  done
fi

# Non-blocking: deprecations show up on the run summary before a nixpkgs bump turns them into errors.
grep -oE "(evaluation warning|trace: warning): .*" "$log" | sort -u | while read -r w; do
  echo "::warning title=Evaluation warning ($attr)::$w"
done
exit "$status"
