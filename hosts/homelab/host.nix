# homelab's host card.
{
  aspects = ["dev" "homelab" "physical" "clickhouse"];

  shared = {
    fireproof.hostname = "homelab";
    fireproof.username = "nickolaj";
  };
}
