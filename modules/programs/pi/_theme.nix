# Pi theme built from the fireproof palette. Pi's `system` theme derives its
# accent hue from the terminal's ANSI magenta, which is why the editor border,
# inline code and list bullets came out magenta; a static theme pins them to
# `accent` instead. Pi paints no base background, so the transcript keeps the
# terminal's own `bg` and only the surfaces below sit a step off it.
{
  lib,
  colors,
}: let
  hex = name: "#${colors.${name}}";

  # Fill for tinted panels: `name` mixed `pct` percent over `bg`. At 20 the panel
  # lands just under `ui`'s luminance, so a hue as bright as flexoki `green`
  # reads as a grey-green surface instead of a block of color; the container
  # step `accentContainer` uses is for small elements with text on top.
  tint = pct: name: let
    # Nix has no hex parser; TOML's 0x integer literal is the shortest way in.
    parse = s: (builtins.fromTOML "v = 0x${s}").v;
    channel = shift: n: builtins.bitAnd (builtins.div n shift) 255;
    mix = shift: let
      hue = channel shift (parse colors.${name});
      base = channel shift (parse colors.bg);
    in
      lib.strings.fixedWidthString 2 "0" (lib.toHexString (builtins.div (hue * pct + base * (100 - pct)) 100));
  in "#${mix 65536}${mix 256}${mix 1}";
in {
  "$schema" = "https://pi.dev/schemas/theme.schema.json";
  name = "fireproof";
  appearance = "dark";

  colors = {
    accent = hex "accent";
    border = hex "blue";
    borderAccent = hex "accent";
    borderMuted = hex "ui";
    success = hex "green";
    error = hex "red";
    warning = hex "yellow";
    muted = hex "fgAlt";
    dim = hex "muted";
    text = hex "fg";
    thinkingText = hex "muted";

    scrollbarTrack = hex "ui";
    scrollbarThumb = hex "fgAlt";
    selectedBg = hex "uiAlt";
    searchMatchBg = hex "accentContainer";
    searchMatchText = hex "fg";

    userMessageBg = hex "bgAlt";
    userMessageText = hex "fg";
    customMessageBg = hex "ui";
    customMessageText = hex "fgAlt";
    customMessageLabel = hex "accent";

    # The only hue-coded box. A finished run sits at half the tint an error does:
    # green is the common case and must not out-shout the prose beside it, while a
    # failed tool is the one row worth looking at twice.
    toolPendingBg = hex "ui";
    toolSuccessBg = tint 10 "green";
    toolErrorBg = tint 20 "red";
    # Dimmer than body text: a tool call is scaffolding around the answer.
    toolTitle = hex "fgAlt";
    toolOutput = hex "fgAlt";

    mdHeading = hex "yellow";
    mdLink = hex "blue";
    mdLinkUrl = hex "muted";
    mdCode = hex "accent";
    mdCodeBlock = hex "green";
    mdCodeBlockBorder = hex "muted";
    mdQuote = hex "fgAlt";
    mdQuoteBorder = hex "uiAlt";
    mdHr = hex "uiAlt";
    mdListBullet = hex "accent";

    toolDiffAdded = hex "green";
    toolDiffRemoved = hex "red";
    toolDiffContext = hex "muted";

    syntaxComment = hex "muted";
    syntaxKeyword = hex "blue";
    syntaxFunction = hex "yellow";
    syntaxVariable = hex "cyan";
    syntaxString = hex "orange";
    syntaxNumber = hex "green";
    syntaxType = hex "accent";
    syntaxOperator = hex "fgAlt";
    syntaxPunctuation = hex "fgAlt";

    # Same order as pi's own ramp (quiet → deep), re-hued to end at the accent
    # instead of violet: this is the editor frame, so its default level shows
    # as the desktop accent.
    thinkingOff = hex "ui";
    thinkingMinimal = hex "muted";
    thinkingLow = hex "cyan";
    thinkingMedium = hex "blue";
    thinkingHigh = hex "accent";
    thinkingXhigh = hex "orange";
    thinkingMax = hex "red";
    bashMode = hex "green";
  };

  export = {
    pageBg = hex "bg";
    cardBg = hex "bgAlt";
    infoBg = hex "ui";
  };
}
