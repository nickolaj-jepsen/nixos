{pkgsUnstable, ...}: {
  environment.systemPackages = [
    (pkgsUnstable.jetbrains.pycharm-professional.override {
      vmopts = ''
        -Dawt.toolkit.name=WLToolkit
      '';
    })
  ];
}
