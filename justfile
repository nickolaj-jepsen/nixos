# `[script]` recipes run under this interpreter; one-liners stay shell recipes.
set script-interpreter := ["bash", "-eu", "-o", "pipefail"]
# Every recipe prints its own error; `[exit-message]` opts a long command back in.
set no-exit-message

nixcmd := "nix --experimental-features 'nix-command flakes'"

# Current Nix system double (e.g. x86_64-linux, aarch64-darwin); agenix-rekey is per-system.
system := `nix --experimental-features 'nix-command flakes' eval --impure --raw --expr 'builtins.currentSystem'`

[default]
[doc('List the recipes')]
list:
    just --list

# A host's routing facts from the flake, space separated: class, needs-root, activation attrpath, rebuild tool.
# The tool goes last: it may contain spaces (`nix run .#home-manager --`), so a final `read` var takes the rest.
[private]
[script]
_meta hostname:
    if ! [[ '{{ hostname }}' =~ ^[a-zA-Z0-9._-]+$ ]]; then
        echo "Not a host name: '{{ hostname }}'" >&2
        exit 1
    fi
    meta=$({{ nixcmd }} eval --raw .#hostMeta --apply 'm: let h = m."{{ hostname }}" or null; in if h == null then "" else "${h.class} ${if h.root then "1" else "0"} ${h.activation} ${h.tool}"')
    if [ -z "$meta" ]; then
        echo "No host '{{ hostname }}' in hosts/ (no host.nix card)." >&2
        exit 1
    fi
    echo "$meta"

# NixOS-only verbs: say so instead of failing on a missing flake attribute.
[private]
[script]
_require-nixos hostname verb:
    read -r class _ <<<"$(just _meta {{ hostname }})"
    if [ "$class" != nixos ]; then
        echo "{{ hostname }} is a $class-class host: '{{ verb }}' is nixos-only — use 'just switch'." >&2
        exit 1
    fi

[doc('Build a host (this machine by default), whatever its class')]
[exit-message]
[group('host')]
[script]
build hostname=`hostname -s` *ARGS="":
    read -r _ _ activation _ <<<"$(just _meta {{ hostname }})"
    $(command -v nom || echo nix) build ".#$activation" {{ ARGS }}

[doc('Print one config value of a host as JSON without building it; an hm. prefix reads its home-manager config')]
[group('host')]
[script]
eval attr hostname=`hostname -s` *ARGS="":
    attr='{{ attr }}'
    valid='^[a-zA-Z0-9._/+"-]+$'
    if ! [[ "$attr" =~ $valid ]]; then
        echo "Not an attribute path: $attr" >&2
        exit 1
    fi
    just _meta {{ hostname }} >/dev/null
    root=$({{ nixcmd }} eval --raw .#hostMeta --apply 'm: m."{{ hostname }}".config')
    if [[ "$attr" == hm.* ]]; then
        # A standalone home config is the HM config itself; the others embed it per user.
        apply="c: (if c ? home-manager then c.home-manager.users.\${c.fireproof.username} else c).${attr#hm.}"
    else
        apply="c: c.$attr"
    fi
    {{ nixcmd }} eval --json ".#$root" --apply "$apply" {{ ARGS }}

[arg('target', pattern='[a-zA-Z0-9._@:+-]*')]
[doc('Build + activate a host (this machine by default); a nixos host can also be pushed to target=user@host')]
[group('host')]
[script]
switch hostname=`hostname -s` target='' *ARGS="":
    read -r class root _ tool <<<"$(just _meta {{ hostname }})"
    if [ -n '{{ target }}' ]; then
        if [ "$class" != nixos ]; then
            echo "Only a nixos host switches remotely: run 'just switch {{ hostname }}' on {{ target }} itself." >&2
            exit 1
        fi
        nixos-rebuild switch --flake .#{{ hostname }} --use-substitutes --target-host '{{ target }}' --sudo {{ ARGS }}
        exit 0
    fi
    if [ "$root" = 1 ]; then sudo="sudo"; else sudo=""; fi
    $sudo $tool switch --flake .#{{ hostname }} {{ ARGS }}
    if [ "$class" = nixos ]; then just _failed-units; fi

[doc('Build + activate a host at next boot (nixos hosts only)')]
[group('host')]
[script]
boot hostname=`hostname -s` *ARGS="":
    just _require-nixos {{ hostname }} boot
    sudo nixos-rebuild boot --flake .#{{ hostname }} {{ ARGS }}

[doc('Build + activate a host until reboot (nixos hosts only)')]
[group('host')]
[script]
test hostname=`hostname -s` *ARGS="":
    just _require-nixos {{ hostname }} test
    sudo nixos-rebuild test --flake .#{{ hostname }} {{ ARGS }}
    just _failed-units

# Activation can succeed while units fail; surface them instead of leaving them to be found later.
[private]
[script]
_failed-units:
    for scope in --system --user; do
        failed=$(systemctl "$scope" --failed --no-legend --plain | awk '{print $1}')
        if [ -n "$failed" ]; then
            echo "⚠ failed units ($scope):"
            echo "$failed" | sed 's/^/  /'
            echo "  inspect: journalctl ${scope/--system/} -b -u <unit>"
        fi
    done

[doc('Diff a host build against the running system (nvd)')]
[group('host')]
[script]
diff hostname=`hostname -s`: (build hostname)
    read -r class _ _ _ <<<"$(just _meta {{ hostname }})"
    current=/run/current-system
    if [ "$class" = home ]; then
        current="${XDG_STATE_HOME:-$HOME/.local/state}/nix/profiles/home-manager"
        if [ ! -e "$current" ]; then
            echo "No home-manager generation for $USER yet: run 'just switch' first." >&2
            exit 1
        fi
    fi
    nvd diff "$current" result

[doc('Run nix-tree on a host (this machine by default)')]
[group('host')]
[script]
tree hostname=`hostname -s` *ARGS="":
    read -r _ _ activation _ <<<"$(just _meta {{ hostname }})"
    nix-tree --derivation ".#$activation" {{ ARGS }}

[arg('package', pattern='[a-zA-Z0-9._+-]+')]
[doc('Show why a package is in a nixos host closure (this machine by default)')]
[group('host')]
[script]
why-depends package hostname=`hostname -s`:
    just _require-nixos {{ hostname }} why-depends
    read -r _ _ activation _ <<<"$(just _meta {{ hostname }})"
    {{ nixcmd }} why-depends --all ".#$activation" ".#nixosConfigurations.{{ hostname }}.pkgs.{{ package }}"

[arg('username', pattern='[a-z_][a-z0-9_-]*')]
[doc('Set up configuration + SSH keys for a new host')]
[group('install')]
new-host hostname username:
    scripts/new-host.sh {{ hostname }} {{ username }}

[arg('target', pattern='[a-zA-Z0-9._@:+-]+')]
[confirm("Deploy " + hostname + " to " + target + "? This will FORMAT disks on the target.")]
[doc('Install a host over ssh with nixos-anywhere (formats the target disks)')]
[group('install')]
deploy-remote hostname target:
    scripts/deploy-remote.sh {{ hostname }} {{ target }}

[arg('target', pattern='[a-zA-Z0-9._@:+-]*')]
[doc('Write hosts/<host>/facter.json from nixos-facter, run here or over ssh on a running target (never reinstalls)')]
[group('install')]
factor hostname=`hostname -s` target='':
    scripts/factor.sh {{ hostname }} '{{ target }}'

[doc('Runs (r)age with yubikey identity')]
[group('secret')]
age *ARGS="--help":
    rage {{ ARGS }} -i ./secrets/yubikey-identity.pub

[arg('file', pattern='[a-zA-Z0-9._/-]+')]
[doc('Decrypt a file to stdout')]
[group('secret')]
decrypt file:
    just age -d {{ file }}

[arg('file', pattern='[a-zA-Z0-9._/-]+')]
[doc('Edit an encrypted secret in $EDITOR (PATH to the .age file) and stage it')]
[group('secret')]
[script]
secret-edit file:
    {{ nixcmd }} run .#agenix-rekey.{{ system }}.edit-view edit "{{ file }}"
    # Stage it: `nix` flake eval ignores git-untracked files, so a new secret is invisible until added.
    if [ -f "{{ file }}" ]; then git add -- "{{ file }}"; fi

# rm first: secret-edit would decrypt the old file to prefill, needing a touch.
[arg('file', pattern='[a-zA-Z0-9._/-]+')]
[doc('Write a secret from stdin, no $EDITOR (PATH to the .age file) - for agents/scripts. Needs no YubiKey; refuses to overwrite unless force=1')]
[group('secret')]
[script]
secret-write file force="":
    if [ -t 0 ]; then
        echo "Error: expects the plaintext secret on stdin, e.g. printf 'KEY=value\n' | just secret-write {{ file }}" >&2
        exit 1
    fi
    if [ -e "{{ file }}" ] && [ -z "{{ force }}" ]; then
        echo "Error: {{ file }} already exists, and stdin would replace it wholesale." >&2
        echo "Use 'just secret-edit {{ file }}' to edit in place (YubiKey), or pass force=1 to discard the current value." >&2
        exit 1
    fi
    umask 077
    temp=$(mktemp -d)
    trap 'rm -rf $temp' EXIT
    cat > "$temp/plaintext"
    if [ ! -s "$temp/plaintext" ]; then
        echo "Error: stdin was empty; refusing to write an empty secret." >&2
        exit 1
    fi
    printf '#!/usr/bin/env bash\ncat %q > "$1"\n' "$temp/plaintext" > "$temp/editor"
    chmod +x "$temp/editor"
    rm -f "{{ file }}"
    EDITOR="$temp/editor" just secret-edit "{{ file }}"
    echo "Wrote {{ file }} - run 'just secret-rekey' (YubiKey) before it can build."

[doc('Create secrets that declare a `generator` and have no file yet (no YubiKey) - follow with secret-rekey')]
[group('secret')]
[script]
secret-generate:
    {{ nixcmd }} run .#agenix-rekey.{{ system }}.generate
    git add -- secrets

[doc('Rekey all secrets - needed when adding secrets/hosts')]
[group('secret')]
[script]
secret-rekey:
    {{ nixcmd }} run .#agenix-rekey.{{ system }}.rekey
    # Stage rekeyed outputs + any new source secrets.
    git add -- secrets

[arg('input', pattern='[a-zA-Z0-9._-]*')]
[doc("Update flake.lock; cache-gated inputs stay put until their build is cached")]
[exit-message]
[group('maintenance')]
[script]
update input='':
    {{ nixcmd }} flake update {{ input }}
    python3 .github/scripts/update_bot.py cache-gate

[doc("Bump the hand-pinned packages in pkgs/ (all, or the named ones)")]
[group('maintenance')]
update-packages *names:
    python3 .github/scripts/update_packages.py {{ prepend("--only ", names) }}

[doc('Format all files using treefmt')]
[group('maintenance')]
fmt:
    {{ nixcmd }} fmt

[doc('Run flake check to validate configuration')]
[exit-message]
[group('maintenance')]
check:
    {{ nixcmd }} flake check

[arg('days', pattern='[0-9]+')]
[confirm("Delete generations and store paths older than " + days + " days?")]
[doc('Collect garbage and delete old generations')]
[group('maintenance')]
[script]
gc days='7':
    sudo nix-collect-garbage --delete-older-than {{ days }}d
    sudo nix-store --optimise

[doc('Remove build results and temporary files')]
[group('maintenance')]
clean:
    rm -rf result result-*

# Two timers do the safe work; `report` changes nothing, `apply` is the checklist.
[arg('action', pattern='report|plan|apply|state|dir|run')]
[doc('What agents and dev tools left behind; `just janitor apply` picks what goes, `just janitor run repo` is the daily pass')]
[group('maintenance')]
janitor action='report' *ARGS:
    janitor {{ action }} {{ ARGS }}

[doc('Generate Markdown reference for the fireproof.* options into docs/')]
[group('dev')]
[script]
docs:
    mkdir -p docs
    out=$({{ nixcmd }} build --no-link --print-out-paths .#fireproof-docs)
    install -m 644 "$out" docs/fireproof-options.md
    echo "Wrote docs/fireproof-options.md"

[doc("Set up what development needs but git ignores: direnv, the pi extensions' node_modules, the mods' types")]
[group('dev')]
[parallel]
dev-setup: _dev-setup-direnv _dev-setup-pi _dev-setup-claude

[private]
_dev-setup-direnv:
    if command -v direnv >/dev/null 2>&1; then direnv allow .; fi

# Links the built pi extensions' node_modules into the repo, for editor types and `pi -e`.
[private]
[script]
[working-directory('modules/programs/pi/extensions')]
_dev-setup-pi:
    {{ nixcmd }} build {{ justfile_directory() }}#pi-extensions --out-link result
    ln -sfn result/node_modules node_modules

[private]
_dev-setup-claude:
    scripts/dev-setup-claude.sh
