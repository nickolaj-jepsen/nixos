{
  flake.aspectTags.zoxide = ["base"];
  flake.modules.homeManager.zoxide = _: {
    config = {
      programs.zoxide = {
        enable = true;
      };
    };
  };
}
