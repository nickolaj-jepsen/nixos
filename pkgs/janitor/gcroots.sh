# Nix GC roots nobody comes back for: `nix build` out-links and nix-direnv's
# profile and input links. `nix-collect-garbage --delete-older-than` only expires
# generations, so without this an out-link pins its closure forever. Removing a
# link costs a rebuild or a refetch; the store gives the space back at the next GC.

# Every root as link<TAB>store path, from the daemon's own list, which sees an
# out-link wherever it was made. Quoting differs across nix versions, and the
# {temp:…}/{censored} entries have no link to act on.
nix_roots() {
  command -v nix-store >/dev/null 2>&1 || return 0
  nix-store --gc --print-roots 2>/dev/null |
    sed -nE 's@^"?(/[^"]*)"? -> "?(/nix/store/[^/"]+)[^"]*"?$@\1\t\2@p'
}

# The cheap shape test, so the thousands of /proc roots never reach a stat.
gcroot_shaped() {
  case "$1" in
  /proc/*) return 1 ;;
  /tmp/* | */.direnv/* | */result | */result-*) return 0 ;;
  esac
  return 1
}

# The group a root's link is freed with, or failure when no rule frees it: a /tmp
# out-link past the temp age, a repo's result* past its age, or the .direnv links
# of a repo idle the way scan_build_dirs means it. Links inside temp sessions go
# with their session, so the tmp rule keeps those.
gcroot_group() {
  local link=$1 top repo last_commit
  # The link's own owner: `test -O` follows it into the root-owned store.
  [ -L "$link" ] && [ "$(stat -c %u -- "$link" 2>/dev/null)" = "$UID" ] || return 1
  protected "$link" && return 1
  case "$link" in
  "$ROOT"/* | "$LEGACY_ROOT"/*) return 1 ;;
  /tmp/*)
    [ "$(age_of "$link")" -ge "$TMP_MAX_AGE_SECONDS" ] || return 1
    top=${link#/tmp/}
    printf '/tmp/%s\n' "${top%%/*}"
    return 0
    ;;
  esac
  repo=$(repo_of_path "$(dirname -- "$link")") || return 1
  is_known_repo "$repo" || return 1
  case "$link" in
  */.direnv/*)
    last_commit=$(git -C "$repo" log -1 --format=%ct 2>/dev/null) || return 1
    [ $((now - last_commit)) -ge "$BUILD_DIR_AGE_SECONDS" ] || return 1
    [ "$(age_of "$link")" -ge "$BUILD_DIR_AGE_SECONDS" ] || return 1
    anything_running_in "$repo" && return 1
    ;;
  *)
    [ "$(age_of "$link")" -ge "$RESULT_AGE_SECONDS" ] || return 1
    ;;
  esac
  printf '%s\n' "$repo"
}

# group<TAB>link<TAB>store path for every root a rule frees; with a group, only
# that group's. Every other root is written to $2 when given: what stays rooted.
gcroot_links() {
  local only=${1:-} kept=${2:-/dev/null} link target group
  while IFS=$'\t' read -r link target; do
    if gcroot_shaped "$link" && group=$(gcroot_group "$link"); then
      [ -z "$only" ] || [ "$group" = "$only" ] || continue
      printf '%s\t%s\t%s\n' "$group" "$link" "$target"
    else
      printf '%s\n' "$target" >>"$kept"
    fi
  done < <(nix_roots | sort -u)
}

# One row per group. The size is what only that group holds: store paths nothing
# else rooted reaches, and that no other row reaches either, so the rows add up.
# It is NAR size, so the store's hard-link optimisation can make the real gain smaller.
scan_gcroots() {
  command -v nix-store >/dev/null 2>&1 || return 0
  local work group count bytes
  work=$(mktemp -d)
  gcroot_links "" "$work/keep" >"$work/cand"
  if [ -s "$work/cand" ]; then
    sort -u "$work/keep" | while IFS= read -r path; do [ -e "$path" ] && printf '%s\n' "$path"; done |
      xargs -r nix-store -qR 2>/dev/null | sort -u >"$work/kept"
    cut -f1 "$work/cand" | sort -u | while IFS= read -r group; do
      awk -F'\t' -v g="$group" '$1 == g {print $3}' "$work/cand" | sort -u |
        while IFS= read -r path; do [ -e "$path" ] && printf '%s\n' "$path"; done |
        xargs -r nix-store -qR 2>/dev/null | sort -u | comm -23 - "$work/kept" |
        awk -v g="$group" '{print g "\t" $0}'
    done >"$work/extra"
    cut -f2 "$work/extra" | sort | uniq -u >"$work/only"
    nix path-info -s --stdin <"$work/only" >"$work/sizes" 2>/dev/null || true
    cut -f1 "$work/cand" | sort -u | while IFS= read -r group; do
      count=$(awk -F'\t' -v g="$group" '$1 == g {n++} END {print n + 0}' "$work/cand")
      # path-info pads the path column with spaces before its tab.
      bytes=$(awk -F'\t' -v g="$group" 'NR == FNR {sub(/ +$/, "", $1); size[$1] = $2 + 0; next}
        $1 == g && ($2 in size) {s += size[$2]} END {print s + 0}' "$work/sizes" "$work/extra")
      printf 'gcroot:%s\tgcroot\t%s\t1\t%s\t%s\t%d nix root(s)\n' \
        "$group" "$bytes" "$group" "$(label_for "$group")" "$count"
    done
  fi
  rm -rf -- "$work"
}

# Remove the links of one group as the rules see them now, and print how many.
gcroot_remove() {
  local group=$1 link removed=0
  while IFS=$'\t' read -r _ link _; do
    rm -f -- "$link" && removed=$((removed + 1))
  done < <(gcroot_links "$group")
  printf '%s\n' "$removed"
}

# A collection right away, so a checklist that just dropped roots shows the space.
# Prints the bytes nix reports freed.
gcroot_collect() {
  command -v nix-store >/dev/null 2>&1 || {
    echo 0
    return
  }
  nix-store --gc 2>&1 | awk '
    / freed$/ {
      n = $(NF - 2); u = $(NF - 1)
      m = (u == "KiB") ? 1024 : (u == "MiB") ? 1048576 : (u == "GiB") ? 1073741824 : (u == "TiB") ? 1099511627776 : 1
      b = n * m
    }
    END {printf "%.0f\n", b + 0}'
}
