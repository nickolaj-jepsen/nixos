# Project workspaces keyed by their niri-dynamic-workspaces switcher key.
let
  local = name: path: {
    inherit name;
    programs = [
      "editor-open ${path}"
      "kitty --directory=${path}"
    ];
  };

  remote = {
    name,
    host,
    path,
    shell ? "fish",
  }: {
    inherit name;
    programs = [
      "editor-open --remote ${host} ${path}"
      "kitty -- ssh -t ${host} 'cd ${path} && exec ${shell} -l'"
    ];
  };
in {
  n = local "nix" "/home/nickolaj/nixos";
  s = local "shop" "/home/nickolaj/dev/devenv-tilt/projects/vvsshop";
  f = local "flex" "/home/nickolaj/dev/devenv-tilt/projects/neoflex";
  u = local "imagine" "/home/nickolaj/dev/devenv-tilt/projects/imagine";
  i = local "insight" "/home/nickolaj/dev/devenv-tilt/projects/insight";
  p = local "producthub" "/home/nickolaj/dev/devenv-tilt/projects/producthub";
  l = local "python-libs" "/home/nickolaj/dev/devenv-tilt/projects/python-libs";
  d = local "devenv" "/home/nickolaj/dev/devenv-tilt";
  y = remote {
    name = "scw-tf";
    host = "dev.ao";
    path = "/home/nij/dev/scw-tf";
  };
}
