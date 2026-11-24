{inputs, ...}: {
  flake.modules.nixos.umbriel = {
    config,
    lib,
    ...
  }: {
    imports = [inputs.umbriel.nixosModules.default];

    # Its package ships start-umbriel, niri-session's twin: login environment in, umbriel.service
    # in session.slice, umbriel-shutdown.target on exit. The module registers it with the greeter.
    config = lib.mkIf (config.fireproof.desktop.enable && config.fireproof.desktop.umbriel.enable) {
      programs.umbriel.enable = true;
      # Like mango, umbriel leaves the power key to logind, whose default is poweroff; niri suspends.
      services.logind.settings.Login.HandlePowerKey = "suspend";
      # niri's choices beside umbriel's own portal (capture, global shortcuts).
      xdg.portal.config.umbriel = {
        "org.freedesktop.impl.portal.FileChooser" = "gnome";
        "org.freedesktop.impl.portal.Secret" = "gnome-keyring";
      };
    };
  };
}
