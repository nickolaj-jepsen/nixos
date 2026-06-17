{
  flake.aspectTags.time = ["base"];
  flake.modules.nixos.time = _: {
    time.timeZone = "Europe/Copenhagen";
  };
}
