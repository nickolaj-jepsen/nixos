# `phone` recipient (nix-on-droid)

This directory holds the **public** key that identifies the phone as an
agenix-rekey recipient — exactly like the other `secrets/hosts/<host>/`
directories, except the phone's key is generated **on the device**, not baked
into a bootstrap ISO.

It is intentionally empty (this README aside) until you complete the on-device
setup. The nix-on-droid secrets scaffold in
`nix-on-droid/phone/default.nix` stays disabled (`builtins.pathExists` guard)
while `id_ed25519.pub` is missing, so the flake keeps evaluating.

To enable secrets, follow the workflow in `nix-on-droid/README.md`:

1. On the phone (inside the nix-on-droid app): `ssh-keygen -t ed25519`
2. Copy the **public** half here as `id_ed25519.pub` (never the private key).
3. Run `just secret-rekey` on your desktop with the YubiKey present.

The private key stays on the phone and is referenced as the agenix decryption
identity (`age.identityPaths`). Do **not** commit it — putting a plaintext key
anywhere a Nix config reads it would copy it into the world-readable Nix store.
