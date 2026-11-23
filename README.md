# NixOS Configuration

My NixOS, nix-darwin and standalone home-manager hosts in one flake, with
agenix-rekey secrets behind a YubiKey.

## Quick start

`just` lists every recipe.

```bash
just switch                  # Rebuild and switch this machine (any host class)
just switch desktop          # ...or a specific host
just switch host user@remote # ...or push a nixos host to a remote
just test                    # Apply until reboot
just build                   # Build without switching
just diff                    # ...and diff the build against the running system
just try zeditor             # One app against the new home-manager config, no switch
just update                  # Update flake inputs
just fmt                     # Format everything
just gc                      # Collect garbage and delete old generations
```

## New machine

```bash
just new-host <hostname> <username>       # card, SSH key, rekey (YubiKey)
just deploy-remote <hostname> root@<ip>   # nixos-anywhere: wipes the target's disks
```

Theme: [Flexoki](https://stephango.com/flexoki).
