# Models in pi

Read this before changing the provider declarations in the pi leaf's
`models.json`, `defaultModel`, `enabledModels`, or the subagent roles in
`modules/programs/pi/agents/`.

## Subscriptions

- OpenCode Go, $10 a month, $40 once Synthetic ends, runs DeepSeek V4.1 Flash,
  one of the two providers behind the default virtual model.
- Kimi.ai Pro, $39 a month, serves K3.1 Pro for hard work. Its five-hour window
  is the scarcest resource we have.
- Claude Max 20x stays for the Claude Code app. Its $200 monthly API credit is
  use-it-or-lose-it; inside pi, Opus and Sonnet on it are hand-picks.
- A ChatGPT plan carries the Codex models through the OAuth credential a
  `/login openai` writes; `ai-usage` tracks its remaining quota.
- Command Code GOAT serves its live multi-provider catalog through the official
  provider package and is the default DeepSeek model's other provider. Its API
  key comes from agenix through `models.json`.
- TensorX (EU, zero retention) and local models are for data-sensitive work,
  picked by hand.
- `_tensorx-models.nix` holds only the models sessions actually pick; it is not
  kept in sync with TensorX's catalog.

## Roles and enabledModels

- Subagent roles pin a model; ordinary roles lock it, because inheritance once
  ran cheap children on Opus.
- Explore, general-purpose, reviewer and verifier run on
  `auto/deepseek-v4.1-flash`, as do the shared side calls.
- retro-reviewer runs on `kimi-coding/k3.1-pro`: a `/retro` starts it at most
  once, when it wants an independent read of the session, so quality outweighs
  its cost.
- Plan runs on `kimi-coding/k3.1-pro`: a plan is judgment work, and it never
  edits.

`enabledModels` has one entry per reason to hand-pick; everything else stays in
the picker's all scope.

- `auto/deepseek-v4.1-flash` first, as the default. It picks OpenCode Go or
  Command Code by the smallest remaining percentage across their 5-hour,
  weekly and monthly windows. Pi keeps the choice on the session branch,
  including retries and compaction; the footer names the provider it picked.
- `opencode-go/deepseek-v4.1-flash` is the explicit physical fallback, and
  `opencode-go/*-free` is for free Go experiments.
- `kimi-coding/k3.1-pro` for hard work and for work Claude declines.
- Opus and Sonnet on the credit.
- `openai-codex/gpt-6.2-astra`, `openai-codex/gpt-6.2-sol` and
  `openai-codex/gpt-6.1-terra` on the ChatGPT plan. pi's bundled catalog ends at GPT-6.1, so 6.2 arrives from the pi.dev
  catalog overlay (`pi update --models`) and is not pinned in `models.json`.
- `command-code/deepseek/deepseek-v4.1-flash` as the subscription's alternate
  DeepSeek route; the rest of its catalog stays in the all scope.
- `local/*` for sensitive work on this host.

## Sensitive and declined work

- A Claude refusal looks like a finished turn, so work a Claude model declines
  goes to `kimi-coding/k3.1-pro` by hand.
- Data-sensitive work goes to local or TensorX. TensorX is not in
  `enabledModels`, so it is picked from the all scope.
- Dedicated cyber tiers are deferred.

## Guardian

- `guardian.ts` asks one judge, picked from the model that made the tool call.
  A subagent's forwarded ask goes by the child's model.
- The judge is never from the actor's family (`judgeFor`): Sonnet judges
  DeepSeek, DeepSeek judges everyone else.
- `PI_JUDGE_MODEL` names one judge for a profile with a single provider
  (pi-work), where the two-family rule has nothing to pick from.
- No judge is less private than the actor or the session it reads. An ask from
  a local or TensorX model, or forwarded into a local or TensorX session, skips
  the judge and goes straight to the dialog.

## The work profile

`pi-work` (the `fireproof.dev.pi.work.enable` toggle) runs the personal config as
a second pi profile in `~/.pi/work`, with its own `auth.json` and this much
different:

- GitHub Copilot is the only provider: nothing else has a key in its
  `models.json` or `auth.json`.
- `enabledModels` is four ids: `fireproof.dev.pi.work.model`, default
  `gpt-6-luna`, leads and is what a session starts on;
  `fireproof.dev.pi.work.fastModel`, default `mai-code-2-flash`, is what the
  subagent roles and the title and judge side calls use, where the personal
  profile uses DeepSeek, through `PI_SIDE_MODEL` and `PI_JUDGE_MODEL`; the other
  two, `mai-code-2` and `gemini-4-hydrogen`, are picked by hand. That list is
  what `/model` starts on and what `Ctrl+P` cycles; `/model` can still widen to
  every model the account reaches.
- `mai-code-2` and `mai-code-2-flash` are `models.json` entries because pi's
  catalog does not carry them yet, though the Copilot API serves them. Each
  entry repeats the Copilot chat headers: a `models` entry replaces the model's
  own, and without them the API answers 400. Delete them once the catalog grows
  the ids. Their prices are the launch promo ones, 50% off until 2027-05-18.
- The DeepSeek router is not loaded: with neither subscription there is nothing
  to route between, and its virtual model would sit in the picker with no
  provider behind it.
- It logs in once with `pi-work auth login github-copilot`. The personal
  `~/.pi/agent/auth.json` is not read, so the two accounts stay apart.
