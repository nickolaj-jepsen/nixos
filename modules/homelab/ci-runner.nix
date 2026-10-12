# Self-hosted runners for CI's Linux build jobs (docs/ci.md): the store and attic are
# local, so a changed host stops pulling its whole closure over the homelab's uplink.
{
  flake.modules.nixos.ci-runner = {
    config,
    lib,
    pkgs,
    ...
  }: let
    runners = map (i: "github-runner-${toString i}") (lib.range 1 3);
  in {
    config = lib.mkIf config.fireproof.homelab.ci-runner.enable {
      # Fine-grained PAT, this repo only, Administration read/write (mints registration tokens).
      age.secrets.github-runner-token.rekeyFile = ../../secrets/hosts/homelab/github-runner-token.age;
      # atticadm token with push+pull on `nixos`; only the post-build-hook reads it.
      age.secrets.attic-push-token.rekeyFile = ../../secrets/hosts/homelab/attic-push-token.age;

      # A user per runner: concurrent jobs can't read each other's processes or workdirs.
      users.groups.github-runner = {};
      users.users = lib.genAttrs runners (_: {
        isSystemUser = true;
        group = "github-runner";
      });

      services.github-runners = lib.genAttrs runners (name: {
        enable = true;
        url = "https://github.com/nickolaj-jepsen/nixos";
        tokenFile = config.age.secrets.github-runner-token.path;
        # Re-registers after every job, so a job can't keep the runner's credentials or leave state for the next one.
        ephemeral = true;
        replace = true;
        noDefaultLabels = true;
        extraLabels = ["homelab"];
        user = name;
        group = "github-runner";
        # GitHub stops sending jobs to runners that fall too far behind, and stable lags.
        package = pkgs.unstable.github-runner;
        extraPackages = [pkgs.gnugrep];
        serviceOverrides = {
          # Same low CPU/IO weight as the daemon's builds, so the homelab's services win.
          Slice = "nix-build.slice";
          # A host eval peaks around 4 GiB.
          MemoryMax = "6G";
          # Root daemons' sockets: tailscaled's is 0666 and dials tailnet peers itself, as root,
          # where the egress firewall below can't see it.
          InaccessiblePaths = map (p: "-/run/${p}") ["tailscale" "docker.sock" "docker" "containerd" "postgresql" "mysqld" "dbus"];
        };
      });
      # The egress firewall goes with firewall.service; so do the runners.
      systemd.services = lib.genAttrs (map (n: "github-runner-${n}") runners) (_: {
        bindsTo = ["firewall.service"];
        after = ["firewall.service"];
      });

      # Allowed, not trusted: a trusted user can pick substituters or disable the sandbox, i.e. root.
      nix.settings.allowed-users = ["@github-runner"];

      # Pushes what this host builds to attic, so jobs never hold an attic token. Runs as root and
      # blocks the build loop; never fails a build because attic is down. Inputs that were
      # substituted (--no-closure) are already in a cache every host uses.
      nix.settings.post-build-hook = let
        # token-file keeps the token out of the store and out of argv.
        atticConfig = pkgs.writeTextDir "attic/config.toml" ''
          default-server = "local"
          [servers.local]
          endpoint = "http://${config.services.atticd.settings.listen}"
          token-file = "${config.age.secrets.attic-push-token.path}"
        '';
      in
        lib.getExe (pkgs.writeShellApplication {
          name = "attic-post-build-hook";
          runtimeInputs = [pkgs.attic-client];
          runtimeEnv.XDG_CONFIG_HOME = atticConfig;
          text = ''
            read -ra paths <<<"$OUT_PATHS"
            attic push --no-closure local:nixos "''${paths[@]}" || echo "attic-post-build-hook: push failed, continuing" >&2
          '';
        });

      # Jobs and FOD builders (the sandbox only cuts the network of other builds) reach the internet
      # but nothing local: the LAN, the tailnet, docker, and this host's own addresses, where services
      # listen behind nginx's SSO; nor multicast/broadcast. resolved's stub is the exception. No IPv6
      # at all: the LAN's global prefix can't be listed, and fetchers fall back to IPv4 on the instant reject.
      networking.firewall.extraCommands = ''
        ip46tables -N fp-ci-egress 2>/dev/null || true
        ip46tables -F fp-ci-egress
        ip46tables -D OUTPUT -j fp-ci-egress 2>/dev/null || true
        ip46tables -I OUTPUT -j fp-ci-egress
        for g in github-runner nixbld; do
          iptables -A fp-ci-egress -m owner --gid-owner "$g" -d 127.0.0.53 -p udp --dport 53 -j RETURN
          iptables -A fp-ci-egress -m owner --gid-owner "$g" -d 127.0.0.53 -p tcp --dport 53 -j RETURN
          iptables -A fp-ci-egress -m owner --gid-owner "$g" -m addrtype --dst-type LOCAL -j REJECT
          iptables -A fp-ci-egress -m owner --gid-owner "$g" -d 0.0.0.0/8,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10,169.254.0.0/16,224.0.0.0/3 -j REJECT
          ip6tables -A fp-ci-egress -m owner --gid-owner "$g" -j REJECT
        done
      '';
      networking.firewall.extraStopCommands = ''
        ip46tables -D OUTPUT -j fp-ci-egress 2>/dev/null || true
        ip46tables -F fp-ci-egress 2>/dev/null || true
        ip46tables -X fp-ci-egress 2>/dev/null || true
      '';
    };
  };
}
