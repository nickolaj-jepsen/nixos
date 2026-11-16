# Plans and design docs

The reader has to decide something, or build from it later.

- Open with the decision or proposal in a sentence or two, then why.
- Goals and non-goals. A non-goal is something a reader might expect that you're deliberately leaving out, not a negated goal.
- Alternatives you considered, each with the reason it lost. A table when they share criteria.
- Show the design concretely: a code sketch, the API call, the file layout, an ASCII mock. An abstract description of an interface is where readers get lost.
- Show the change itself, not only its interface: the config, unit or function you'd add, trimmed to what a reviewer needs.
- Say how the proposal itself can fail once it runs: a missing tool on PATH, an exit code that marks it failed, an environment it doesn't inherit.
- Headers for the parts (proposal, alternatives, open questions), so a reviewer can find the one they need.
- Prose for the reasoning, bullets for steps and separate items. One diagram if parts talk to each other.
- As long as the decision needs. Skip the doc when there's no real tradeoff.
- A question to the reader says what you'd pick and why, so "yes" answers it.

## Examples

An abstract question to a concrete one:

```text
Should the config layer resolve inheritance eagerly or lazily?

→
Should `load("prod")` return the merged config straight away?

    cfg = load("prod")        # prod.toml on top of base.toml
    cfg.db.pool_size          # 20, from prod
    cfg.db.timeout            # 5, inherited from base

The other option merges on each access, which keeps edits to base.toml live
but makes every lookup walk the chain. I'd merge on load: configs don't
change while running.
```

The first version needs the reader to work out what "eagerly" means here. The second shows it.

A pitch in slides to a pitch in prose: eleven slides of headers and bullets became two short paragraphs and two code blocks, one showing the problem and one the fix. The headers went because there were only two things to say.
