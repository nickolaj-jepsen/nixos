# Design system

`fireproof.theme` (`modules/base/theme/`) is the single source for colors, fonts
and the logo. `config.fireproof.theme.designSystem` renders it into a static
bundle: `tokens.css`, `tokens.json`, `logo/`, `fonts/` and a specimen
`index.html`. `just design-system` previews it with live rebuilds;
`.github/workflows/pages.yml` publishes it to GitHub Pages from `main`.

## Traps

- Token names are derived from option names (`colors.bgAlt` → `--fp-bg-alt`,
  `semantic.error` → `--fp-error`, `brand.flame.outer` → `--fp-flame-outer`).
  Renaming an option renames its token and breaks anything reading
  `tokens.css`.
- Templates in `brand/` may only use the `@flameOuter@`, `@flameMid@`,
  `@flameCore@` and `@ink@` placeholders and need a `0 0 W H` viewBox; the build
  fails otherwise. A new template becomes a new row of logo variants on its own.
- The specimen groups colors by rule, not by list: `<name>Alt` and
  `<name>Container` attach to `<name>`, low-chroma colors are neutrals, the rest
  are hues. Only the brand trio (`bg`, `fg`, `accent`) is hand-picked, in
  `_design-system.nix`.
- Semantic roles are declared inside `semanticGroups` in `default.nix`, which
  the specimen uses for its columns. A new role goes into one of the groups,
  not straight into `options.fireproof.theme.semantic`.
- Font files are picked by family name (`font-faces.py`): `font.sans.family`
  and `font.monoFamily` must match the files' family exactly or the build
  fails.
- `checks.py` fails the build when a pair in its `REQUIRED` list drops below
  its contrast ratio, or when touching flame layers get too close to tell
  apart. Hues that sit too close only warn, on the page and in the
  build log (`nix build -L`).
- `.#design-system` is read from the desktop host, so it exists only on
  x86_64-linux.

## Decisions

- Dark only. There is no light palette; the `-light` logo variants use `bg` as
  ink.
- The flame's outer layer and the wordmark's "fire" are `accent`, so the mark
  follows the accent. The middle and core are brand-only colors, lighter than
  the palette's orange and yellow, because pixel art reads by lightness and
  `orange` sits too close to `accent` to show as its own layer.
- No webfonts. The bundle ships the theme's own font files, which makes the
  page about 12 MB, mostly Hack Nerd Font.
- Nunito Sans is its own package (`pkgs/nunito-sans`) because
  `google-fonts.override` fetches the whole ~3 GB google/fonts tree.

## Roadmap

Not started, most useful first:

- Pull `accent` away from `red` and `orange`. The Contrast section shows them
  under 0.06 apart, so the primary button reads as an error or warning.
- Lift `red` (`error`, `removed`) to 4.5:1 on `bg`; it is 3.97:1, so error
  text fails WCAG AA.
- Move the remaining hue-for-meaning reads to `semantic.*` (niri's urgent
  border, Glance's storage warning).
- Shape and type tokens: corner radius (DMS hard-codes 8) and the type scale.
- A light palette, with `tokens.css` emitting both modes.
- PNG/ICO exports for favicons and plymouth.
- Glance reading `tokens.css`, with the flame as favicon.
- woff2-compress the bundled fonts.
- Logo shapes as Nix data, so layouts compose from the flame and the two
  words.
- A claude.ai Design System artifact, published from the bundle by a skill.
