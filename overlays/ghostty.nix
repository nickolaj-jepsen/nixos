{inputs, ...}: {
  perSystem = {system, ...}: {
    overlayAttrs = {
      ghostty = inputs.ghostty.packages.${system}.default;
    };
  };
}
