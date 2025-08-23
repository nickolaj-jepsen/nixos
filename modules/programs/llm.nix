{
  pkgs,
  config,
  username,
  pkgsUnstable,
  ...
}: let
  llmConfig =
    if pkgs.stdenv.isDarwin
    then "Library/Application Support/io.datasette.llm"
    else ".config/io.datasette.llm";
  pythonEnv = pkgsUnstable.python3.withPackages (pp:
    with pp; [
      llm
      llm-anthropic
      llm-gemini
      llm-tools-sqlite
      llm-fragments-github
      llm-cmd
      llm-jq
      llm-github-copilot
      llm-git
    ]);
  llmPkgWithPlugins = pkgs.writeShellScriptBin "llm" ''
    unset PYTHONPATH # Otherwise it breaks in Python devenvs
    export $(grep -v '^#' ${config.age.secrets.llm-api-key.path} | xargs)
    exec ${pythonEnv}/bin/llm "''${@}"
  '';
in {
  age.secrets.llm-api-key = {
    rekeyFile = ../../secrets/llm-api-key.env.age;
    mode = "0600";
    owner = username;
  };

  environment.systemPackages = [
    llmPkgWithPlugins
  ];

  fireproof.home-manager = {
    home.file = {
      "${llmConfig}/templates/cli.yaml".text = builtins.toJSON {
        model = "gpt-5-nano";
        prompt = ''
          Please help the user with a question regarding the linux cli.

          - Be concise and informative
          - If you recommend any commands or tools, make sure to explain their usage.

          This is the users question:
          $input
        '';
      };
    };
  };
}
