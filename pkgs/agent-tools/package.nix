# The agent plugins' sources, checked: the harness-free cores type-check and pass
# their own tests here. Each agent's leaf builds its half from `$out/plugins/<name>`
# against the agent that runs it.
{
  buildNpmPackage,
  importNpmLock,
}:
buildNpmPackage {
  pname = "agent-tools";
  version = "0";
  src = ../../agent-tools;
  npmDeps = importNpmLock {npmRoot = ../../agent-tools;};
  inherit (importNpmLock) npmConfigHook;
  dontNpmBuild = true;
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    npm run typecheck
    npm test
    runHook postCheck
  '';
  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp -r plugins $out/
    runHook postInstall
  '';
}
