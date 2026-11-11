# What is filling the disk, biggest first, each with the command that clears it.
# Read-only: it measures and prints, and never deletes anything itself.
#
# Every check runs in parallel; the nix store scan sets the pace (~45 s). Paths
# other users own (/tmp, the journal) are counted only as far as they are readable.

# A check that fails reports less, it does not stop the others.
set +e

out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

# Bytes in the given paths, 0 when none exist.
bytes() {
  local p existing=()
  for p in "$@"; do [ -e "$p" ] && existing+=("$p"); done
  [ "${#existing[@]}" -eq 0 ] && { echo 0; return; }
  du -scb "${existing[@]}" 2>/dev/null | tail -1 | cut -f1
}

human() { numfmt --to=iec-i --suffix=B --format=%.1f "$1"; }

# The n biggest entries of a directory as "name size, name size".
top() {
  local dir=$1 n=${2:-3}
  [ -d "$dir" ] || return 0
  find "$dir" -mindepth 1 -maxdepth 1 -print0 2>/dev/null |
    xargs -0r du -sb 2>/dev/null | sort -rn | head -n "$n" |
    while IFS=$'\t' read -r size path; do printf '%s %s, ' "${path##*/}" "$(human "$size")"; done |
    sed 's/, $//'
}

# emit <key> <bytes> <label> <detail> <command>...: one entry, sorted by bytes.
# A bytes of -1 is a size this cannot measure; it sorts last and prints "?".
emit() {
  local key=$1 size=$2 label=$3 detail=$4
  shift 4
  [[ $size =~ ^-?[0-9]+$ ]] || return 0
  [ "$size" = 0 ] && return 0
  {
    echo "$size"
    printf '%s\t%s\n' "$label" "$detail"
    printf '%s\n' "$@"
  } >"$out/$key"
}

check_nix_store() {
  local total dead count
  total=$(bytes /nix/store)
  mapfile -t dead < <(nix-store --gc --print-dead 2>/dev/null)
  count=${#dead[@]}
  local freed=0
  if [ "$count" -gt 0 ]; then
    freed=$(printf '%s\n' "${dead[@]}" | xargs nix path-info --json 2>/dev/null |
      jq -s '[.[] | .[]? | .narSize? // 0] | add // 0')
  fi
  emit nix-store "$total" "nix store" "$count dead paths, up to $(human "$freed") free now (optimise hard links can make it less)" \
    "nix-store --gc                    # dead paths only" \
    "nh clean all --keep-since 3d      # also old generations and result links (sudo)"
}

check_nix_cache() {
  emit nix-cache "$(bytes "$HOME/.cache/nix")" "nix eval/fetch cache" "~/.cache/nix" \
    "rm -rf ~/.cache/nix"
}

check_agent_tmp() {
  local root=${XDG_STATE_HOME:-$HOME/.local/state}/agents/tmp sessions
  sessions=$(find "$root" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | wc -l)
  emit agent-tmp "$(bytes "$root")" "agent scratch" "$sessions sessions; biggest repos: $(top "$root")" \
    "systemd-tmpfiles --user --clean   # sessions untouched for 3 days"
}

check_tmp() {
  emit tmp "$(bytes /tmp)" "/tmp" "readable part; biggest: $(top /tmp)" \
    "sudo systemd-tmpfiles --clean     # entries older than 10 days" \
    "rm -rf /tmp/<name>"
}

check_docker() {
  command -v docker >/dev/null || return 0
  timeout 10 docker info >/dev/null 2>&1 || return 0
  # Docker prints decimal units ("3.312GB", "189MB (100%)").
  local type size reclaim count active key cmd label
  while IFS=$'\t' read -r type size reclaim count active; do
    case $type in
      Images) key=images label="docker images" cmd="docker image prune -a            # every image no container uses" ;;
      Containers) key=containers label="docker containers" cmd="docker container prune           # stopped containers" ;;
      "Local Volumes") key=volumes label="docker volumes" cmd="docker volume prune -a           # unused volumes, named ones too: their data goes" ;;
      "Build Cache") key=build label="docker build cache" cmd="docker builder prune -a" ;;
      *) continue ;;
    esac
    emit "docker-$key" "$(numfmt --from=si "${size%B}")" "$label" "$count total, $active in use, ${reclaim} reclaimable" "$cmd"
  done < <(docker system df --format '{{.Type}}\t{{.Size}}\t{{.Reclaimable}}\t{{.TotalCount}}\t{{.Active}}' 2>/dev/null)
}

check_uv() {
  local dir
  dir=$(uv cache dir 2>/dev/null || echo "$HOME/.cache/uv")
  emit uv "$(bytes "$dir")" "uv cache" "$dir" \
    "uv cache prune                    # entries no longer used" \
    "uv cache clean                    # everything"
}

check_pnpm() {
  emit pnpm "$(bytes "${XDG_DATA_HOME:-$HOME/.local/share}/pnpm/store" "$HOME/.pnpm-store")" "pnpm store" "content-addressed packages" \
    "pnpm store prune                  # packages no project references"
}

check_npm() {
  emit npm "$(bytes "$HOME/.cache/npm" "$HOME/.npm")" "npm cache" "~/.cache/npm" \
    "npm cache clean --force"
}

check_pip() {
  emit pip "$(bytes "$HOME/.cache/pip")" "pip cache" "~/.cache/pip" \
    "rm -rf ~/.cache/pip"
}

check_go() {
  emit go "$(bytes "$HOME/go/pkg/mod" "$HOME/.cache/go-build")" "go caches" "module cache and build cache" \
    "nix shell nixpkgs#go -c go clean -cache -modcache"
}

check_cargo() {
  emit cargo "$(bytes "$HOME/.cargo/registry" "$HOME/.cargo/git" "$HOME/.cache/cargo-build")" "cargo caches" "registry, git checkouts, build-dir intermediates" \
    "rm -rf ~/.cargo/registry/cache ~/.cargo/git/checkouts ~/.cache/cargo-build"
}

check_gradle() {
  emit gradle "$(bytes "$HOME/.cache/gradle/caches" "$HOME/.cache/gradle/wrapper")" "gradle caches" "dependencies and wrapper distributions" \
    "rm -rf ~/.cache/gradle/caches ~/.cache/gradle/wrapper"
}

# ~/.cache minus what the entries above already count.
check_cache_other() {
  local claimed=" uv npm pip go-build nix gradle cargo-build pnpm " dir name paths=()
  for dir in "$HOME"/.cache/*/; do
    name=$(basename "$dir")
    [[ $claimed == *" $name "* ]] || paths+=("$dir")
  done
  [ "${#paths[@]}" -eq 0 ] && return 0
  local biggest
  biggest=$(du -sb "${paths[@]}" 2>/dev/null | sort -rn | head -4 |
    while IFS=$'\t' read -r size path; do path=${path%/}; printf '%s %s, ' "${path##*/}" "$(human "$size")"; done | sed 's/, $//')
  emit cache-other "$(bytes "${paths[@]}")" "other ~/.cache" "biggest: $biggest" \
    "rm -rf ~/.cache/<name>            # caches refill themselves"
}

check_build_dirs() {
  local roots=() r report total projects
  for r in "$HOME/dev" "$HOME/nixos" "$HOME/worktrees"; do [ -d "$r" ] && roots+=("$r"); done
  [ "${#roots[@]}" -eq 0 ] && return 0
  report=$(kondo --dry-run --older 2M "${roots[@]}" 2>/dev/null | tail -1)
  # "Projects cleaned: 0/8, Bytes deleted: 0.0B / 354.9MiB"
  projects=$(sed -n 's|.*Projects cleaned: [0-9]*/\([0-9]*\).*|\1|p' <<<"$report")
  total=$(sed -n 's|.* / \([0-9.]*[KMGT]\?\)i\?B$|\1|p' <<<"$report")
  [ -n "$total" ] || return 0
  emit build-dirs "$(numfmt --from=iec "$total")" "build dirs" "${projects:-0} projects idle 2+ months (node_modules, target, .venv...)" \
    "kondo -o 2M ~/dev ~/nixos ~/worktrees   # pick per project" \
    "kondo --dry-run -o 2M ~/dev             # just list them"
}

check_worktrees() {
  local root=${WT_WORKTREE_ROOT:-$HOME/worktrees} count
  count=$(find "$root" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | wc -l)
  emit worktrees "$(bytes "$root")" "worktrees" "$count open; biggest repos: $(top "$root")" \
    "wt clean                          # those whose work is in the default branch" \
    "wt list                           # then wt close <name>"
}

check_journal() {
  command -v journalctl >/dev/null || return 0
  local size
  size=$(journalctl --disk-usage 2>/dev/null | sed -n 's/.*take up \([0-9.]*[KMGT]\?\).*/\1/p')
  [ -n "$size" ] || return 0
  emit journal "$(numfmt --from=iec "$size")" "systemd journal" "this user's view of it" \
    "sudo journalctl --vacuum-size=200M"
}

check_trash() {
  emit trash "$(bytes "${XDG_DATA_HOME:-$HOME/.local/share}/Trash")" "trash" "~/.local/share/Trash" \
    "rm -rf ~/.local/share/Trash/{files,info,expunged}"
}

check_transcripts() {
  emit transcripts "$(bytes "$HOME/.claude/projects" "$HOME/.claude-work/projects" "$HOME/.pi/agent/sessions")" \
    "agent transcripts" "kept on purpose: auto-gate and /mine read them" \
    "find ~/.claude*/projects ~/.pi/agent/sessions -name '*.jsonl' -mtime +180 -delete   # older than 6 months"
}

check_models() {
  emit models "$(bytes "$HOME/models")" "local models" "biggest: $(top "$HOME/models")" \
    "rm ~/models/<file>.gguf"
}

check_vms() {
  emit vms "$(bytes "$HOME/vms")" "VM images" "biggest: $(top "$HOME/vms")" \
    "rm ~/vms/<image>                  # shut the VM down first"
}

check_steam() {
  emit steam "$(bytes "${XDG_DATA_HOME:-$HOME/.local/share}/Steam")" "Steam" "games and shader caches" \
    "# Steam → Settings → Storage, uninstall what you don't play"
}

check_downloads() {
  emit downloads "$(bytes "$HOME/Downloads")" "Downloads" "biggest: $(top "$HOME/Downloads")" \
    "rm ~/Downloads/<file>"
}

# Snapshot sizes need root (squota), so only the count is shown.
check_snapshots() {
  local dir=/mnt/btrfs/@snapshots count
  [ -d "$dir" ] || return 0
  count=$(find "$dir" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
  [ "$count" -gt 0 ] || return 0
  emit snapshots -1 "btrbk snapshots" "$count of @home; they pin what was deleted since they were taken" \
    "sudo btrfs qgroup show -re --sort=-excl /mnt/btrfs | head   # size them" \
    "sudo btrfs subvolume delete $dir/<name>"
}

checks=(
  check_nix_store check_nix_cache check_agent_tmp check_tmp check_docker
  check_uv check_pnpm check_npm check_pip check_go check_cargo check_gradle
  check_cache_other check_build_dirs check_worktrees check_journal check_trash
  check_transcripts check_models check_vms check_steam check_downloads check_snapshots
)

echo "measuring ${#checks[@]} places, the nix store takes longest..." >&2
for c in "${checks[@]}"; do "$c" & done
wait

if [ -t 1 ]; then bold=$'\e[1m' dim=$'\e[2m' reset=$'\e[0m'; else bold='' dim='' reset=''; fi

df -h --output=avail,size,pcent / | tail -1 | {
  read -r avail size pcent
  printf '%s%s free of %s on / (%s used)%s\n\n' "$bold" "$avail" "$size" "$pcent" "$reset"
}

for f in "$out"/*; do
  [ -e "$f" ] || continue
  printf '%s\t%s\n' "$(head -1 "$f")" "$f"
done | sort -t$'\t' -k1,1nr | while IFS=$'\t' read -r size f; do
  IFS=$'\t' read -r label detail < <(sed -n 2p "$f")
  if [ "$size" = -1 ]; then shown='?'; else shown=$(human "$size"); fi
  printf '%s%8s  %-20s%s %s\n' "$bold" "$shown" "$label" "$reset" "$detail"
  tail -n +3 "$f" | while IFS= read -r cmd; do printf '          %s$ %s%s\n' "$dim" "$cmd" "$reset"; done
done

printf '\n%sAnything else: dust -d 2 ~%s\n' "$dim" "$reset"
