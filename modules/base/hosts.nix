{config, ...}: {
  age.secrets.hosts-private = {
    # Contains IP addresses that i have no business sharing
    rekeyFile = ../../secrets/hosts-private.age;
  };

  # Inject the private hosts file, because setting networking.hostFiles doesn't work
  system.activationScripts.hosts-private = ''
    cat /etc/hosts > /etc/hosts.bak
    rm /etc/hosts
    cat /etc/hosts.bak "${config.age.secrets.hosts-private.path}" >> /etc/hosts
    rm /etc/hosts.bak
  '';
}
