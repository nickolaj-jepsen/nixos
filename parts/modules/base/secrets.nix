{hostname, ...}: let
  hostSecrets = ../../../secrets/hosts + ("/" + hostname);
  publicKey = builtins.readFile (hostSecrets + "/id_ed25519.pub");
in {
  age.rekey = {
    storageMode = "local";
    hostPubkey = publicKey;
    masterIdentities = [
      {
        identity = ../../../secrets/yubikey-identity.pub;
        # pubkey = "age1yubikey1q25a8ax2t0ujv7q5wvpmlpa52h599n6682jprxuftlw4zpxy2xu9s6lhrel";
      }
    ];
    extraEncryptionPubkeys = [
      "age1pzrfw28f8qvsk9g8p2stundf4ph466jut0g6q47sse76zljtqy9q2w32zr" # Backup key (bitwarden)
    ];
    localStorageDir = hostSecrets + /.rekey;
    generatedSecretsDir = hostSecrets;
  };
}
