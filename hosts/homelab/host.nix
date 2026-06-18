# homelab's host card.
{
  aspects = ["dev" "homelab" "physical" "clickhouse" "networkd"];

  shared = {
    fireproof.hostname = "homelab";
    fireproof.username = "nickolaj";
  };
}
