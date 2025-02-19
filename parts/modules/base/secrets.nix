{hostname, ...}: let
  hostSecrets = ../../../secrets/hosts + ("/" + hostname);
  publicKey = builtins.readFile (hostSecrets + "/id_ed25519.pub");
in {
  age.identityPaths = ["/etc/ssh/ssh_host_ed25519_key"];
  age.rekey = {
    storageMode = "local";
    hostPubkey = publicKey;
    masterIdentities = [
      {
        identity = ../../../secrets/yubikey-identity.pub;
      }
    ];
    extraEncryptionPubkeys = [
      "age1pzrfw28f8qvsk9g8p2stundf4ph466jut0g6q47sse76zljtqy9q2w32zr" # Backup key (bitwarden)
    ];
    localStorageDir = hostSecrets + /.rekey;
    generatedSecretsDir = hostSecrets;
  };
}
