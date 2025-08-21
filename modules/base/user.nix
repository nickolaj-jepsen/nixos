{
  username,
  config,
  ...
}: let
  inherit (config.age) secrets;
in {
  config = {
    age.secrets.hashed-user-password.rekeyFile = ../../secrets/hashed-user-password.age;

    users.users.${username} = {
      isNormalUser = true;
      extraGroups = ["wheel"];
      hashedPasswordFile = secrets.hashed-user-password.path;
    };
  };
}
