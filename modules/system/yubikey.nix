{
  flake.modules.nixos.yubikey = _: {
    services.pcscd.enable = true;

    # pcscd's polkit defaults need an active logind session, which WSL's
    # /init.scope, systemd units and agent shells don't have.
    security.polkit.extraConfig = ''
      polkit.addRule(function(action, subject) {
        if ((action.id == "org.debian.pcsc-lite.access_pcsc"
             || action.id == "org.debian.pcsc-lite.access_card")
            && subject.isInGroup("wheel")) {
          return polkit.Result.YES;
        }
      });
    '';
  };
}
