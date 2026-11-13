# Puts Nix's version of each writable app config back (fireproof.writableConfigs),
# saving what the app changed since the last reset first. See usage below.
# Uses MANIFEST ([{name, path, source}]) and STATE, set by the Nix wrapper.

keep=50

usage() {
  cat >&2 <<'EOF'
config-reset [NAME...]        reset (all by default)
config-reset diff [NAME...]   what changed since the last reset, without resetting
config-reset log [NAME...]    saved changes, newest first
config-reset show NAME [N]    the Nth newest saved change (default 1)
EOF
  exit 2
}

# One "name<TAB>path<TAB>source" line per selected entry; no names selects all.
entries() {
  local all
  all=$(jq -r '.[] | [.name, .path, .source] | @tsv' "$MANIFEST")
  if (($# == 0)); then
    printf '%s\n' "$all"
    return
  fi
  local name line found
  for name in "$@"; do
    found=
    while IFS= read -r line; do
      if [[ ${line%%$'\t'*} == "$name" ]]; then
        printf '%s\n' "$line"
        found=1
      fi
    done <<<"$all"
    if [[ -z $found ]]; then
      echo "config-reset: unknown config '$name'; known: $(jq -r 'map(.name) | join(", ")' "$MANIFEST")" >&2
      exit 2
    fi
  done
}

# Sorted keys, so a reordering by the app is not a change. Not JSON (comments): as is.
normalize() {
  jq -S . "$1" 2>/dev/null || cat "$1"
}

# What the app changed: the last baseline against the live file. Exits 1 on a change.
changes() {
  local name=$1 path=$2 source=$3 base="$STATE/$1/baseline"
  [[ -f $base ]] || base=$source
  # A symlink is a previous generation's store file, not something the app wrote.
  [[ -f $path && ! -L $path ]] || return 0
  diff -u --label "$name (nix)" --label "$name (live)" <(normalize "$base") <(normalize "$path")
}

reset() {
  local name path source dir stamp
  local list
  list=$(entries "$@")
  while IFS=$'\t' read -r name path source; do
    [[ -n $name ]] || continue
    dir="$STATE/$name"
    mkdir -p "$dir"
    stamp=$(date +%Y-%m-%dT%H%M%S)
    # Two resets in one second (a switch right after a manual one) keep both.
    while [[ -e $dir/$stamp.diff ]]; do stamp+=_; done
    if ! changes "$name" "$path" "$source" >"$dir/$stamp.diff"; then
      cp "$path" "$dir/$stamp-$(basename "$path")"
      echo "$name: kept the app's changes, see config-reset show $name"
    else
      rm "$dir/$stamp.diff"
    fi

    if [[ -L $path ]] || ! cmp -s "$source" "$path"; then
      if [[ -L $path ]]; then rm "$path"; fi
      mkdir -p "$(dirname "$path")"
      # In place, not a rename: the running app's file watch stays on it and reloads.
      cat "$source" >"$path"
      chmod 644 "$path"
      echo "$name: reset to nix"
    fi
    install -m644 "$source" "$dir/baseline"

    find "$dir" -maxdepth 1 -name '*.diff' -printf '%f\n' | sort -r | tail -n +$((keep + 1)) |
      while IFS= read -r old; do rm -f "$dir/$old" "$dir/${old%.diff}"-*; done
  done <<<"$list"
}

diff_cmd() {
  local name path source any=
  local list
  list=$(entries "$@")
  while IFS=$'\t' read -r name path source; do
    [[ -n $name ]] || continue
    changes "$name" "$path" "$source" || any=1
  done <<<"$list"
  [[ -n $any ]] || echo "no changes since the last reset" >&2
}

log_cmd() {
  local name path source f stamp added removed
  local list
  list=$(entries "$@")
  while IFS=$'\t' read -r name path source; do
    [[ -n $name ]] || continue
    [[ -d "$STATE/$name" ]] || continue
    while IFS= read -r f; do
      stamp=${f%.diff}
      added=$(grep -c '^+[^+]' "$STATE/$name/$f" || true)
      removed=$(grep -c '^-[^-]' "$STATE/$name/$f" || true)
      printf '%-24s %s  +%s -%s\n' "$name" "$stamp" "$added" "$removed"
    done < <(find "$STATE/$name" -maxdepth 1 -name '*.diff' -printf '%f\n' | sort -r)
  done <<<"$list"
}

show_cmd() {
  (($# >= 1)) || usage
  entries "$1" >/dev/null
  local n=${2:-1} f
  f=$(find "$STATE/$1" -maxdepth 1 -name '*.diff' -printf '%f\n' 2>/dev/null | sort -r | sed -n "${n}p")
  if [[ -z $f ]]; then
    echo "config-reset: $1 has no saved change #$n" >&2
    exit 1
  fi
  cat "$STATE/$1/$f"
}

case ${1-} in
-h | --help | help) usage ;;
diff) shift && diff_cmd "$@" ;;
log) shift && log_cmd "$@" ;;
show) shift && show_cmd "$@" ;;
*) reset "$@" ;;
esac
