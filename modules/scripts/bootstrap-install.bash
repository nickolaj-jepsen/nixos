set -euo pipefail

# Auto-elevate. The bootstrap ISO autologins as the unprivileged `nixos`
# user (upstream `installation-device.nix` default); the MOTD just says
# `bootstrap-install`, so re-exec under sudo if we're not root.
if [ "$(id -u)" -ne 0 ]; then
    exec sudo --preserve-env=TERM "$0" "$@"
fi

HOST=$(cat /etc/iso-bootstrap/target-host)
SRC=/etc/iso-bootstrap/nixos
WORK=/tmp/nixos
EXTRA=/tmp/extra-files
LUKS_PATH=/luks-password

echo "=== Bootstrap install for ${HOST} ==="

# Refuse to run if a previous attempt left state behind — disko would
# fail confusingly, and worse, a saved disk-configuration.nix from the
# prior run might point at a /dev/sdX that USB-enumeration has since
# shifted onto an unrelated drive.
if mountpoint -q /mnt 2>/dev/null; then
    echo "Error: /mnt is already mounted (prior run didn't tear down)." >&2
    echo "Reboot the ISO and try again." >&2
    exit 1
fi
if mountpoint -q /nix/store 2>/dev/null && \
   awk '$2=="/nix/store"{print $3}' /proc/mounts | grep -q '^overlay$'; then
    echo "Error: /nix/store is already overlay-mounted from a prior run." >&2
    echo "Reboot the ISO and try again." >&2
    exit 1
fi

confirm() {
    local prompt="$1" reply
    read -rp "${prompt} [y/N] " reply
    [[ "${reply}" =~ ^[Yy] ]]
}

# Prompt for a 1..max integer, looping until the input is valid. Echoes
# the chosen index to stdout.
prompt_index() {
    local prompt="$1" max="$2" reply
    while true; do
        read -rp "${prompt}" reply
        if [[ "${reply}" =~ ^[0-9]+$ ]] && [ "${reply}" -ge 1 ] && [ "${reply}" -le "${max}" ]; then
            printf '%s' "${reply}"
            return 0
        fi
        echo "Please enter a number between 1 and ${max}." >&2
    done
}

# Escape sed replacement metacharacters (`\`, `&`, and the delimiter `|`)
# so a disk path with vendor-string ampersands or backslashes survives
# template substitution unchanged.
sed_quote_replacement() {
    printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'
}

# State flags + cleanup. Trap is set EARLY so /tmp/extra-files (which
# holds the decrypted host SSH identity — the agenix master key) is
# shredded even if we abort during the disk prompts.
LUKS_WRITTEN=0
OVERLAY_MOUNTED=0
cleanup() {
    if [ "${OVERLAY_MOUNTED}" -eq 1 ]; then
        umount /nix/store 2>/dev/null || umount -l /nix/store 2>/dev/null || true
    fi
    if [ "${LUKS_WRITTEN}" -eq 1 ] && [ -e "${LUKS_PATH}" ]; then
        shred -u "${LUKS_PATH}" 2>/dev/null || rm -f "${LUKS_PATH}"
    fi
    if [ -d "${EXTRA}" ]; then
        find "${EXTRA}" -type f -exec shred -u {} + 2>/dev/null || true
        rm -rf "${EXTRA}"
    fi
}
trap cleanup EXIT

# 1. Writable copy of the baked flake.
#    `-L` dereferences symlinks — etc activation makes /etc/iso-bootstrap/nixos
#    a tree of per-file symlinks into the read-only store, and a plain `cp -r`
#    would carry those symlinks into /tmp where `chmod` then follows them back
#    into the store (EROFS).
rm -rf "${WORK}"
cp -rL "${SRC}" "${WORK}"
chmod -R u+w "${WORK}"
cd "${WORK}"

# 2. Stage the host SSH key. Mode 700 on the directory — only root reads it.
rm -rf "${EXTRA}"
install -d -m700 "${EXTRA}"
install -m600 /etc/iso-bootstrap/ssh/id_ed25519     "${EXTRA}/ssh_host_ed25519_key"
install -m644 /etc/iso-bootstrap/ssh/id_ed25519.pub "${EXTRA}/ssh_host_ed25519_key.pub"

# 3. Disko config. If the host already has one and the user wants to keep it,
#    the disk path comes from that config — no disk prompt needed. Otherwise
#    we ask for a disk and substitute it into a template.
DISKO="hosts/${HOST}/disk-configuration.nix"
PICK_DISKO=0
CHOSEN_DISK=""
if [ ! -s "${DISKO}" ] || ! grep -q "disko.devices" "${DISKO}"; then
    PICK_DISKO=1
else
    echo
    echo "Existing disk-configuration.nix found for ${HOST}."
    if confirm "Replace it with a template?"; then
        PICK_DISKO=1
    fi
fi

if [ "${PICK_DISKO}" -eq 1 ]; then
    # 3a. Pick the target disk. Enumerate via `lsblk` (so virtio disks without
    #     a serial still show up) and prefer the stable /dev/disk/by-id/ alias
    #     when one exists, falling back to /dev/<name>.
    declare -A BYID
    shopt -s nullglob
    for d in /dev/disk/by-id/*; do
        base=$(basename "$d")
        case "${base}" in
            wwn-*) continue ;;
            *-part[0-9]*) continue ;;
        esac
        real=$(readlink -f "$d" 2>/dev/null) || continue
        name=$(basename "${real}")
        [ -z "${BYID[$name]:-}" ] && BYID[$name]="${d}"
    done
    shopt -u nullglob

    DISK_PATHS=()
    DISK_LABELS=()
    while read -r name type size model_rest; do
        [ "${type}" = "disk" ] || continue
        by_id="${BYID[$name]:-}"
        if [ -n "${by_id}" ]; then
            path="${by_id}"
            label=$(printf "%-8s %-8s %s [by-id: %s]" "${name}" "${size}" "${model_rest:-(no model)}" "$(basename "${by_id}")")
        else
            path="/dev/${name}"
            label=$(printf "%-8s %-8s %s (no by-id alias)" "${name}" "${size}" "${model_rest:-(no model)}")
        fi
        DISK_PATHS+=("${path}")
        DISK_LABELS+=("${label}")
    done < <(lsblk -dn -o NAME,TYPE,SIZE,MODEL)

    if [ "${#DISK_PATHS[@]}" -eq 0 ]; then
        echo "No disks found by lsblk" >&2
        exit 1
    fi

    echo
    echo "Available disks:"
    for i in "${!DISK_PATHS[@]}"; do
        printf "  [%d] %s\n" "$((i+1))" "${DISK_LABELS[i]}"
    done
    DISK_IDX=$(prompt_index "Pick disk number: " "${#DISK_PATHS[@]}")
    CHOSEN_DISK="${DISK_PATHS[$((DISK_IDX-1))]}"
    echo "Selected: ${CHOSEN_DISK}"

    # 3b. Pick template and substitute the disk in.
    echo
    echo "Pick a disko template:"
    shopt -s nullglob
    TEMPLATES=(hosts/_templates/disko/*.nix)
    shopt -u nullglob
    if [ "${#TEMPLATES[@]}" -eq 0 ]; then
        echo "No templates found in hosts/_templates/disko/" >&2
        exit 1
    fi
    for i in "${!TEMPLATES[@]}"; do
        name=$(basename "${TEMPLATES[i]}" .nix)
        printf "  [%d] %s\n" "$((i+1))" "${name}"
    done
    TPL_IDX=$(prompt_index "Pick template number: " "${#TEMPLATES[@]}")
    CHOSEN_TPL="${TEMPLATES[$((TPL_IDX-1))]}"
    CHOSEN_DISK_ESC=$(sed_quote_replacement "${CHOSEN_DISK}")
    sed "s|@@DISK@@|${CHOSEN_DISK_ESC}|" "${CHOSEN_TPL}" > "${DISKO}"
    echo "Wrote ${DISKO} from template $(basename "${CHOSEN_TPL}")"
fi

# 4. Facter — live-generate if missing. Existing facter.json is kept unless
#    the user opts in to regenerating.
FACTER="hosts/${HOST}/facter.json"
GEN_FACTER=0
if [ ! -f "${FACTER}" ]; then
    GEN_FACTER=1
else
    echo
    echo "Existing facter.json found for ${HOST}."
    if confirm "Regenerate it for this hardware?"; then
        GEN_FACTER=1
    fi
fi
if [ "${GEN_FACTER}" -eq 1 ]; then
    echo "==> Generating facter.json"
    nixos-facter -o "${FACTER}"
fi

# 5. LUKS detection via the canonical NixOS option (`boot.initrd.luks.devices`)
#    rather than grepping the disko config — disko populates this option
#    regardless of how the user structures their disk-configuration.nix.
HAS_LUKS=$(nix --experimental-features "nix-command flakes" eval \
    "${WORK}#nixosConfigurations.${HOST}.config.boot.initrd.luks.devices" \
    --apply '(d: d != {})' 2>/dev/null || echo "false")

if [ "${HAS_LUKS}" = "true" ]; then
    while true; do
        read -rsp "LUKS passphrase: " LUKS1; echo
        read -rsp "Confirm LUKS passphrase: " LUKS2; echo
        if [ "${LUKS1}" = "${LUKS2}" ] && [ -n "${LUKS1}" ]; then break; fi
        echo "Passphrases don't match or are empty. Try again."
    done
    printf "%s" "${LUKS1}" > "${LUKS_PATH}"
    chmod 600 "${LUKS_PATH}"
    LUKS_WRITTEN=1
fi

# 6. Final confirmation — last chance to abort before destroying data.
echo
echo "About to format and install:"
echo "  Host:  ${HOST}"
if [ -n "${CHOSEN_DISK}" ]; then
    echo "  Disk:  ${CHOSEN_DISK}  (WILL BE WIPED)"
else
    echo "  Disk:  per existing hosts/${HOST}/disk-configuration.nix  (WILL BE WIPED)"
fi
if [ "${HAS_LUKS}" = "true" ]; then
    echo "  LUKS:  yes"
fi
if ! confirm "Proceed?"; then
    echo "Aborted by user."
    exit 1
fi

# 7. Format and mount the target disk. We do this in two steps (disko then
#    nixos-install) rather than via disko-install so we can interpose a
#    /nix/store overlay between formatting and the install — the live ISO
#    runs on tmpfs, so without redirecting nix builds onto the new disk a
#    desktop closure won't fit in RAM.
echo
echo "==> Formatting disk (disko)"
disko --mode destroy,format,mount --flake "${WORK}#${HOST}"

# Disko has consumed the passphrase — shred immediately rather than leaving
# the plaintext on tmpfs for the full install window.
if [ "${LUKS_WRITTEN}" -eq 1 ] && [ -e "${LUKS_PATH}" ]; then
    shred -u "${LUKS_PATH}" 2>/dev/null || rm -f "${LUKS_PATH}"
    LUKS_WRITTEN=0
fi

# 8. Place the host SSH key *before* nixos-install. The install runs the
#    agenix activation script which decrypts secrets (incl. the user's
#    hashedPasswordFile) using /etc/ssh/ssh_host_ed25519_key — if the key
#    isn't on disk yet, decryption silently fails and the user is created
#    without a password, locking them out of the DE.
install -m755 -d /mnt/etc/ssh
install -m600 "${EXTRA}/ssh_host_ed25519_key"     /mnt/etc/ssh/ssh_host_ed25519_key
install -m644 "${EXTRA}/ssh_host_ed25519_key.pub" /mnt/etc/ssh/ssh_host_ed25519_key.pub

# 9. Overlay /mnt/nix/store on top of the live /nix/store. New store paths
#    written by `nixos-install` land on the disk instead of tmpfs.
#    `workdir` must live on the same mount as `upperdir`, so we place it
#    under /mnt/nix (which is its own subvolume in btrfs configs) rather
#    than under /mnt.
echo "==> Redirecting /nix/store writes onto the target disk"
install -d /mnt/nix/store /mnt/nix/.overlay-work
mount -t overlay overlay \
    -o "lowerdir=/nix/store,upperdir=/mnt/nix/store,workdir=/mnt/nix/.overlay-work" \
    /nix/store
OVERLAY_MOUNTED=1

# 10. Install the system. Snapshot flake.lock first — `nix build` (via
#     nixos-install) can refresh registry timestamps, and we don't want
#     that churn to surface as a phantom `git diff` after first boot.
LOCK_BACKUP=$(mktemp)
cp "${WORK}/flake.lock" "${LOCK_BACKUP}"
echo "==> Installing NixOS"
nixos-install --root /mnt --flake "${WORK}#${HOST}" --no-channel-copy --no-root-password
cp "${LOCK_BACKUP}" "${WORK}/flake.lock"
rm -f "${LOCK_BACKUP}"

# 11. Tear down the overlay. Lazy fallback in case nix-daemon (or a stray
#     builder child) still holds the mount; the contents of upperdir are
#     already persisted to /mnt/nix/store on disk either way.
umount /nix/store 2>/dev/null || umount -l /nix/store 2>/dev/null || true
OVERLAY_MOUNTED=0
rm -rf /mnt/nix/.overlay-work

# 12. Stage the (possibly modified) flake into the installed user's home so any
#     live-generated facter.json / disk-configuration.nix shows up as `git diff`
#     after first boot.
TARGET_USER=$(nix --experimental-features "nix-command flakes" eval --raw \
    "${WORK}#nixosConfigurations.${HOST}.config.fireproof.username")
USER_HOME="/mnt/home/${TARGET_USER}"
HOME_PRECREATED=0
if [ ! -d "${USER_HOME}" ]; then
    install -d -m755 "${USER_HOME}"
    HOME_PRECREATED=1
fi
install -d -m755 "${USER_HOME}/nixos"
cp -a "${WORK}/." "${USER_HOME}/nixos/"
USER_UID=$(awk -F: -v u="${TARGET_USER}" '$1==u{print $3}' /mnt/etc/passwd)
USER_GID=$(awk -F: -v u="${TARGET_USER}" '$1==u{print $4}' /mnt/etc/passwd)
if [ -n "${USER_UID}" ] && [ -n "${USER_GID}" ]; then
    if [ "${HOME_PRECREATED}" -eq 1 ]; then
        chown "${USER_UID}:${USER_GID}" "${USER_HOME}"
    fi
    chown -R "${USER_UID}:${USER_GID}" "${USER_HOME}/nixos"
fi

echo
echo "=== Done ==="
echo "Reboot, then: cd ~/nixos && git status"
echo "Any live-generated configs (facter.json, disk-configuration.nix) will appear there."
