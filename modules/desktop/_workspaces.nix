# Project workspaces keyed by their niri-dynamic-workspaces switcher key.
# Each key binds a template, because only a template records the `cwd` that
# `niri-dynamic-workspaces cwd` prints back for umbriel-workspace-kitty.
let
  local = name: path: {
    inherit name;
    template = {
      title = name;
      cwd = path;
      programs = [
        "editor-open ${path}"
        "kitty --directory=${path}"
      ];
    };
  };

  remote = {
    name,
    host,
    path,
    shell ? "fish",
  }: {
    inherit name;
    template = {
      title = name;
      # No cwd: the path is on the remote host, not here.
      programs = [
        "editor-open --remote ${host} ${path}"
        "kitty -- ssh -t ${host} 'cd ${path} && exec ${shell} -l'"
      ];
    };
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
