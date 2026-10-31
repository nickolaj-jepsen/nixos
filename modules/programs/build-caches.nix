# Build caches under ~/.cache, which hosts keep out of /home's snapshots.
{
  flake.modules.homeManager.build-caches = {
    config,
    lib,
    pkgs,
    ...
  }: let
    cache = config.xdg.cacheHome;
    vars = {
      GRADLE_USER_HOME = "${cache}/gradle";
      npm_config_cache = "${cache}/npm";
    };
  in {
    config = lib.mkIf config.fireproof.dev.enable {
      home.sessionVariables = vars;
      # Apps launched from the desktop (IDEs) don't inherit the shell's variables.
      systemd.user.sessionVariables = lib.mkIf pkgs.stdenv.isLinux vars;

      # Intermediate artifacts (deps/, incremental/); final binaries stay in target/.
      home.file.".cargo/config.toml".text = ''
        [build]
        build-dir = "${cache}/cargo-build/{workspace-path-hash}"
      '';

      # Overrides every project's jvmargs. Setting jvmargs at all drops Gradle's default metaspace cap,
      # and an idle Gradle + Kotlin daemon pair holds ~7 GiB for the default 3 h. No
      # org.gradle.priority=low: it's a relative nice, so an agent's daemon would land at 19.
      xdg.cacheFile."gradle/gradle.properties".text = ''
        org.gradle.jvmargs=-Xmx2g -XX:MaxMetaspaceSize=1g -XX:+UseParallelGC -Dfile.encoding=UTF-8
        org.gradle.daemon.idletimeout=3600000
        org.gradle.java.installations.auto-download=false
        org.gradle.java.installations.fromEnv=JAVA_HOME
      '';
    };
  };
}
