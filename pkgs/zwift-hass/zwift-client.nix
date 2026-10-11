{
  buildPythonPackage,
  hatchling,
  requests,
  protobuf,
  src,
}:
buildPythonPackage {
  pname = "zwift-client";
  version = "0.2.0";
  pyproject = true;
  inherit src;
  doCheck = false;
  build-system = [hatchling];
  dependencies = [
    requests
    protobuf
  ];
}
