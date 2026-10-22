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

  # Fill for tinted panels: `name` mixed 20% over `bg`. That lands a panel just
  # under `ui`'s luminance, so a hue as bright as flexoki `green` reads as a
  # grey-green surface instead of a block of color; the container step
  # `accentContainer` uses is for small elements with text on top.
  tint = name: let
    # Nix has no hex parser; TOML's 0x integer literal is the shortest way in.
    parse = s: (builtins.fromTOML "v = 0x${s}").v;
    channel = shift: n: builtins.bitAnd (builtins.div n shift) 255;
    mix = shift: let
      hue = channel shift (parse colors.${name});
      base = channel shift (parse colors.bg);
    in
      lib.strings.fixedWidthString 2 "0" (lib.toHexString (builtins.div (hue * 20 + base * 80) 100));
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

    # The only hue-coded box: a finished run reads green at panel brightness.
    toolPendingBg = hex "ui";
    toolSuccessBg = tint "green";
    toolErrorBg = tint "red";
    toolTitle = hex "fg";
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
