{config, ...}: {
  programs.ssh.startAgent = true;
  services.openssh.hostKeys = [
    {
      type = "ed25519";
      inherit (config.age.secrets.id_ed25519) path;
    }
  ];
  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = false;
    settings.KbdInteractiveAuthentication = false;
  };

  users.users.${config.user.username}.openssh.authorizedKeys.keys = [
    "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC/oT15GWYcRvWCTchReh5rnkXTC9Ukm6Zfufei9bq1fWB0EjpvosCMupADw+jvqiP/ttyBKewHwZQxiw9oeRPSphUtKB0UlQXFPASNf1VxrFlsbkDOSEa+FB+PBS3eeP0TTyNJh18oYszt/OFDzCvr1n53iGXTX9xm76bkBxVfAvhm/5vadjmXKGOpdM/OWNF8rCqSgwkME6PXdT1UAFVj+FBdLrNCqYh1pe1ZdRxYlYL5b4uHwQmuz57AkvWwRNKipzdtxMCkT3LNiCQzuOhv3QaqxQ6fgJ+ktkbcTLZtY7HdT+CRUuC+APr266jeLAz1yUxFH693QifbBdn8v7wWD++UnbP23QqNwdXEMnCjEPRFgnK4ERnhIq6jVR328f5DTRJHZZ9spEx7pWsiT2iQC8MxK0gk9xul4fduJsPETWXe84YaHe6wLK92SQKQMdLh6p+TBvhMhPW2PrH5C6iH2w1oXVGlhc4wvoB1leiKNVHf4m9CWRFgznSmVbxFHFk= nickolaj@arch-desktop"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFtjpdHPRXg75YBonNshQdeuNZ3W3k/RzdYY+8QuQ3Pc nickolaj1177@gmail.com"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMdBiNbNPcMdI/hp4zgBS3ShqYuVVRvUAA1ffrdiBQ0k nickolaj@fireproof.website"
  ];
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC/oT15GWYcRvWCTchReh5rnkXTC9Ukm6Zfufei9bq1fWB0EjpvosCMupADw+jvqiP/ttyBKewHwZQxiw9oeRPSphUtKB0UlQXFPASNf1VxrFlsbkDOSEa+FB+PBS3eeP0TTyNJh18oYszt/OFDzCvr1n53iGXTX9xm76bkBxVfAvhm/5vadjmXKGOpdM/OWNF8rCqSgwkME6PXdT1UAFVj+FBdLrNCqYh1pe1ZdRxYlYL5b4uHwQmuz57AkvWwRNKipzdtxMCkT3LNiCQzuOhv3QaqxQ6fgJ+ktkbcTLZtY7HdT+CRUuC+APr266jeLAz1yUxFH693QifbBdn8v7wWD++UnbP23QqNwdXEMnCjEPRFgnK4ERnhIq6jVR328f5DTRJHZZ9spEx7pWsiT2iQC8MxK0gk9xul4fduJsPETWXe84YaHe6wLK92SQKQMdLh6p+TBvhMhPW2PrH5C6iH2w1oXVGlhc4wvoB1leiKNVHf4m9CWRFgznSmVbxFHFk= nickolaj@arch-desktop"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFtjpdHPRXg75YBonNshQdeuNZ3W3k/RzdYY+8QuQ3Pc nickolaj1177@gmail.com"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMdBiNbNPcMdI/hp4zgBS3ShqYuVVRvUAA1ffrdiBQ0k nickolaj@fireproof.website"
  ];
}
