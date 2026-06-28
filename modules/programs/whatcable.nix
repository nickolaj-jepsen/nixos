# WhatCable cable identifier on darwin: a Homebrew cask. No declarative HM half —
# Mac-only utility with local state.
{
  flake.modules.darwin.whatcable = {
    config,
    lib,
    ...
  }: {
    config = lib.mkIf config.fireproof.desktop.enable {
      homebrew.casks = ["whatcable"];
    };
  };
}
