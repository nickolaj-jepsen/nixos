{
  pkgsUnstable,
  username,
  config,
  ...
}: {
  age.secrets.llm-api-key = {
    rekeyFile = ../../secrets/llm-api-key.env.age;
    mode = "0600";
    owner = username;
  };

  environment.systemPackages = with pkgsUnstable; [
    aider-chat
  ];
  fireproof.home-manager = {
    home.file.".aider.conf.yml".text = ''
      # Aider configuration file
      # This file is used to configure the Aider chat client
      # It is a YAML file
      sonnet: true
      env-file: ${config.age.secrets.llm-api-key.path}
    '';
  };
}
