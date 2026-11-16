# Docstrings and comments

The reader is at the call site or in a diff, with the code in front of them.

- A comment says what the code can't: the why, a gotcha, a constraint, units or bounds. Never what the next line does.
- A docstring is the contract: enough to call the function without reading its body. One imperative line, then only what that line can't carry (errors, side effects, invariants).
- Don't restate the signature or the types.
- Name other code by symbol, not by file and line, and don't list callers.
- Default to one line.
- For trimming existing comments, `prune-comments` has the full rules.

## Examples

Keep only the why:

```text
# aarch64 emulation so this x86_64 host can cross-build the Raspberry Pi
# kiosk SD image (~/dev/kiosk). Some derivations run target binaries at
# build time (e.g. writeShellScript's bash -n), which fails without binfmt.
boot.binfmt.emulatedSystems = ["aarch64-linux"];

→ # cross-builds the Raspberry Pi kiosk SD image
```

The code already says it enables emulation. The only thing it can't say is why this host needs it.

A docstring that labels, not narrates:

```text
"""A radio telescope at dusk in 1-bit Atkinson dither: an empty sky above,
grain gathering in the bowl and along the horizon."""
→ """A radio telescope at dusk in one-bit Atkinson dither."""
```
