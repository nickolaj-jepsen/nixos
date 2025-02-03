{config, ...}: {
  environment.variables = {
    EDITOR = config.defaults.editor;
  };
}
