{
  flake.modules.nixos.hosts = {
    config,
    pkgs,
    ...
  }: {
    age.secrets.hosts-private = {
      # Contains IP addresses that i have no business sharing
      rekeyFile = ../../secrets/hosts-private.age;
    };

    # Inject the private hosts file, because setting networking.hostFiles doesn't work.
    # Rewrite a marked block rather than append: WSL's /etc/hosts isn't reset on activation.
    system.activationScripts.hosts-private = {
      deps = ["etc" "agenix"];
      text = ''
        tmp=$(mktemp /etc/hosts.XXXXXX)
        ${pkgs.gnused}/bin/sed '/^# BEGIN hosts-private$/,/^# END hosts-private$/d' /etc/hosts > "$tmp"
        {
          echo '# BEGIN hosts-private'
          cat "${config.age.secrets.hosts-private.path}"
          echo '# END hosts-private'
        } >> "$tmp"
        chmod 644 "$tmp"
        mv "$tmp" /etc/hosts
      '';
    };
  };
}
