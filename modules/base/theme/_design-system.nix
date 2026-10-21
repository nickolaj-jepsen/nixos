# Renders `fireproof.theme` into a static bundle: tokens.{css,json}, logo/*.svg,
# fonts/ and a specimen index.html. Tokens and the specimen are generated from
# the option attrsets, so a new color or brand/*.svg layout needs no edit here.
{
  lib,
  pkgs,
  theme,
  # Option descriptions of `theme.colors`, shown on the swatches.
  descriptions,
}: let
  inherit (theme) colors brand font;

  kebab = lib.stringAsChars (c:
    if lib.elem c lib.upperChars
    then "-${lib.toLower c}"
    else c);

  # colors.bgAlt -> bg-alt, brand.flame.outer -> flame-outer
  paletteTokens = lib.mapAttrs' (name: lib.nameValuePair (kebab name)) colors;
  # Logo colors; the page's "brand colors" are the primary palette entries below.
  brandTokens = lib.concatMapAttrs (group: lib.mapAttrs' (name: lib.nameValuePair "${group}-${kebab name}")) brand;
  colorTokens = paletteTokens // brandTokens;

  fontTokens = {
    sans = ''"${font.sans.family}", sans-serif'';
    mono = ''"${font.monoFamily}", monospace'';
  };

  tokensCss = pkgs.writeText "tokens.css" ''
    :root {
    ${lib.concatStrings (lib.mapAttrsToList (name: hex: "  --fp-${name}: #${hex};\n") colorTokens)}${
      lib.concatStrings (lib.mapAttrsToList (name: value: "  --fp-font-${name}: ${value};\n") fontTokens)
    }}
  '';

  tokensJson = pkgs.writeText "tokens.json" (builtins.toJSON {
    colors = lib.mapAttrs (_: hex: "#${hex}") colors;
    brand = lib.mapAttrsRecursive (_: hex: "#${hex}") brand;
    font = {
      sans = font.sans.family;
      mono = font.monoFamily;
    };
  });

  layouts = map (lib.removeSuffix ".svg") (lib.attrNames (builtins.readDir ./brand));

  # "light" variants are for light backgrounds: ink is the dark bg color.
  treatments = let
    color = ink: {
      inherit ink;
      inherit (brand.flame) outer mid core;
    };
    mono = ink: {
      inherit ink;
      outer = ink;
      mid = ink;
      core = ink;
    };
  in {
    color = color colors.fg;
    color-light = color colors.bg;
    mono = mono colors.fg;
    mono-light = mono colors.bg;
  };

  logos = lib.concatMap (layout: let
    template = lib.trim (builtins.readFile ./brand/${layout}.svg);
    size = builtins.match ''.*viewBox="0 0 ([0-9]+) ([0-9]+)".*'' template;
  in
    lib.mapAttrsToList (treatment: t: let
      name = "${layout}-${treatment}.svg";
      svg =
        lib.replaceStrings ["@flameOuter@" "@flameMid@" "@flameCore@" "@ink@"] [t.outer t.mid t.core t.ink]
        template;
    in
      assert lib.assertMsg (!lib.hasInfix "@" svg) "brand/${layout}.svg has an unknown @placeholder@";
      assert lib.assertMsg (size != null) "brand/${layout}.svg needs a `0 0 W H` viewBox"; {
        inherit name layout treatment;
        file = pkgs.writeText name (svg + "\n");
        width = lib.toInt (lib.elemAt size 0);
        height = lib.toInt (lib.elemAt size 1);
      })
    treatments)
  layouts;

  # Integer scales keep the crispEdges pixel art sharp.
  findLogo = name: lib.findFirst (logo: logo.name == name) (throw "design system: no ${name}") logos;
  logoImg = scale: logo: ''<img src="logo/${logo.name}" alt="fireproof" width="${toString (logo.width * scale)}" height="${toString (logo.height * scale)}">'';

  # Swatch grouping is computed so a new color lands in the right section on its own:
  # `<name>Alt`/`<name>Container` are companions of `<name>`, low-chroma colors are neutrals.
  primary = lib.filter (name: colors ? ${name}) ["bg" "fg" "accent"];
  names = lib.attrNames colors;
  channels = hex: map (i: lib.fromHexString (lib.substring i 2 hex)) [0 2 4];
  chroma = hex: let c = channels hex; in lib.foldl' lib.max 0 c - lib.foldl' lib.min 255 c;
  isCompanion = base: name: name != base && lib.hasPrefix base name && lib.elem (lib.substring (lib.stringLength base) 1 name) lib.upperChars;
  companions = base: lib.filter (isCompanion base) names;
  roots = lib.filter (name: !lib.any (base: isCompanion base name) names) names;
  isNeutral = name: chroma colors.${name} < 32;
  hueAngle = hex: let
    c = map (x: x * 1.0) (channels hex);
    r = lib.elemAt c 0;
    g = lib.elemAt c 1;
    b = lib.elemAt c 2;
    max = lib.foldl' lib.max 0.0 c;
    d = max - lib.foldl' lib.min 255.0 c;
    h =
      if d == 0.0
      then 0.0
      else if max == r
      then 60 * (g - b) / d
      else if max == g
      then 60 * ((b - r) / d + 2)
      else 60 * ((r - g) / d + 4);
  in
    if h < 0
    then h + 360
    else h;
  hues = lib.sort (a: b: hueAngle colors.${a} < hueAngle colors.${b}) (lib.filter (name: !lib.elem name primary && !isNeutral name) roots);
  neutrals = lib.sort (a: b: luminance colors.${a} < luminance colors.${b}) (lib.filter isNeutral names);
  # Swatch label color: whichever of bg/fg contrasts more (WCAG ratio, gamma approximated as 2).
  luminance = hex: let
    c = map (x: x / 255.0 * (x / 255.0)) (channels hex);
  in
    0.2126 * lib.elemAt c 0 + 0.7152 * lib.elemAt c 1 + 0.0722 * lib.elemAt c 2;
  contrast = a: b: let
    la = luminance a;
    lb = luminance b;
  in
    (lib.max la lb + 0.05) / (lib.min la lb + 0.05);
  ink = name: "#${
    if contrast colors.${name} colors.bg > contrast colors.${name} colors.fg
    then colors.bg
    else colors.fg
  }";

  chip = name: ''<div class="chip" style="background: var(--fp-${kebab name}); color: ${ink name}"><code>${kebab name}</code><code>#${colors.${name}}</code></div>'';

  brandColor = name: ''
    <article class="brand-color" style="background: var(--fp-${kebab name}); color: ${ink name}">
      <span class="sample">Aa</span>
      <div><h3>${kebab name}</h3><p>${descriptions.${name}}</p><code>--fp-${kebab name} &middot; #${colors.${name}}</code></div>
      <div class="companions">${lib.concatMapStrings chip (companions name)}</div>
    </article>
  '';

  hueCard = name: ''
    <article class="hue">
      ${lib.concatMapStrings chip ([name] ++ companions name)}
      <p>${descriptions.${name}}</p>
    </article>
  '';

  section = number: title: body: ''
    <section>
      <header><span>${number}</span><h2>${title}</h2></header>
      ${body}
    </section>
  '';

  typeRow = label: style: text: ''<div class="type-row"><code>${label}</code><p style="${style}">${text}</p></div>'';

  hero = findLogo "lockup-color.svg";

  indexHtml = pkgs.writeText "index.html" ''
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Fireproof design system</title>
    <link rel="icon" href="logo/flame-color.svg">
    <link rel="stylesheet" href="tokens.css">
    <link rel="stylesheet" href="specimen.css">
    </head>
    <body>
    <main>
    <header class="hero">
      ${logoImg 8 hero}
      <p>Colors, type and marks for fireproof machines, generated from <code>fireproof.theme</code>.</p>
      <nav><a href="tokens.css">tokens.css</a><a href="tokens.json">tokens.json</a></nav>
    </header>

    ${section "01" "Brand colors" ''
      <div class="brand-colors">${lib.concatMapStrings brandColor primary}</div>
    ''}

    ${section "02" "Neutrals" ''
      <div class="ramp">${lib.concatMapStrings chip neutrals}</div>
    ''}

    ${section "03" "Hues" ''
      <div class="hues">${lib.concatMapStrings hueCard hues}</div>
    ''}

    ${section "04" "Type" ''
        <p class="family">${font.sans.family} <span>for UI and prose</span></p>
        ${typeRow "56 / 800" "font-size: 56px; font-weight: 800; line-height: 1.05" "Fireproof"}
        ${typeRow "32 / 700" "font-size: 32px; font-weight: 700; line-height: 1.2" "Every host, one theme"}
        ${typeRow "20 / 600" "font-size: 20px; font-weight: 600" "Colors flow from a single module"}
        ${typeRow "16 / 400" "font-size: 16px" "The quick brown fox jumps over the lazy dog. 0123456789"}
        ${typeRow "13 / 400" "font-size: 13px; color: var(--fp-muted)" "Muted caption text for metadata and hints"}
        <p class="family">${font.monoFamily} <span>for code and terminals</span></p>
        <pre class="code"><span class="c"># a module leaf reading the theme</span>
      <span class="k">let</span> c = config.fireproof.theme.colors; <span class="k">in</span> {
        background = c.bg;
        border = <span class="s">"#''${c.accent}"</span>;
        opacity = <span class="n">0.95</span>;
      }</pre>
    ''}

    ${section "05" "In use" ''
      <div class="demo">
        <div class="buttons"><button class="primary">Rebuild</button><button>Diff</button><button class="ghost">Cancel</button></div>
        <div class="alert" style="--tone: var(--fp-red)"><strong>Build failed</strong> attribute 'foo' missing</div>
        <div class="alert" style="--tone: var(--fp-orange)"><strong>Warning</strong> option renamed, update hosts/desktop</div>
        <div class="alert" style="--tone: var(--fp-green)"><strong>Switched</strong> desktop is on generation 412</div>
        <div class="alert" style="--tone: var(--fp-blue)"><strong>Info</strong> 3 inputs have updates</div>
      </div>
    ''}

    ${section "06" "Logo" ''
      <div class="logo-feature">
        <figure>${logoImg 6 hero}</figure>
        <figure class="light">${logoImg 6 (findLogo "lockup-color-light.svg")}</figure>
      </div>
      <div class="flame-colors">
        <span>Flame colors, for the mark only</span>
        ${lib.concatStrings (lib.mapAttrsToList (name: hex: ''<code><i style="background: var(--fp-${name})"></i>--fp-${name} #${hex}</code>'') brandTokens)}
      </div>
      <h3 class="sub">All variants</h3>
      ${lib.concatMapStrings (layout: ''
          <div class="variants">${lib.concatMapStrings (logo: ''
            <figure class="${lib.optionalString (lib.hasSuffix "light" logo.treatment) "light"}">${logoImg 3 logo}<figcaption>${logo.name}</figcaption></figure>
          '') (lib.filter (logo: logo.layout == layout) logos)}</div>
        '')
        layouts}
    ''}
    </main>
    </body>
    </html>
  '';

  fontFaces = family: package: ''
    find ${package}/share/fonts -type f -print0 \
      | xargs -0 python3 -I ${./font-faces.py} $out/fonts ${lib.escapeShellArg family}
  '';
in
  pkgs.runCommand "fireproof-design-system" {
    nativeBuildInputs = [(pkgs.python3.withPackages (ps: [ps.fonttools]))];
  } ''
    mkdir -p $out/logo $out/fonts
    ${lib.concatMapStrings (logo: "cp ${logo.file} $out/logo/${logo.name}\n") logos}
    {
      ${fontFaces font.sans.family font.sans.package}
      ${fontFaces font.monoFamily font.package}
      cat ${tokensCss}
    } > $out/tokens.css
    cp ${tokensJson} $out/tokens.json
    cp ${indexHtml} $out/index.html
    cp ${./specimen.css} $out/specimen.css
  ''
