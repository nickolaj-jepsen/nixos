{...}: {
  services.keyd = {
    enable = true;
    keyboards.default = {
      ids = [ "*" ];
      settings = {
        main = {
          # Bind mouse-foward to meta+middlemouse if held
          mouse2 = "timeout(mouse2, 150, M-middlemouse)";
          # Bind mouse-back to meta if held
          mouse1 = "overload(meta, mouse1)";
        };
      };
    };
  };
}