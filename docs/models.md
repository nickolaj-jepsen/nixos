# Models in pi

Read this before changing the provider declarations in the pi leaf's
`models.json`, `defaultModel`, `enabledModels`, or the subagent roles in
`modules/programs/pi/agents/`.

## Subscriptions

- OpenCode Go, $10 a month, $40 once Synthetic ends, runs DeepSeek V4.1 Flash,
  the workhorse and the default model.
- Kimi.ai Pro, $39 a month, serves K3.1 Pro for hard work. Its five-hour window
  is the scarcest resource we have.
- Claude Max 20x stays for the Claude Code app. Its $200 monthly API credit is
  use-it-or-lose-it; inside pi, Opus and Sonnet on it are hand-picks.
- A ChatGPT plan carries the Codex models through the OAuth credential a
  `/login openai` writes; `ai-usage` tracks its remaining quota.
- TensorX (EU, zero retention) and local models are for data-sensitive work,
  picked by hand.
- `_tensorx-models.nix` holds only the models sessions actually pick; it is not
  kept in sync with TensorX's catalog.

## Roles and enabledModels

- Subagent roles pin a model; ordinary roles lock it, because inheritance once
  ran cheap children on Opus. `handoff-review` pins Sol but allows the caller's
  per-invocation model override.
- Explore, general-purpose, reviewer and verifier run on
  `opencode-go/deepseek-v4.1-flash`.
- retro-reviewer runs on `kimi-coding/k3.1-pro`: a `/retro` starts it at most
  once, when it wants an independent read of the session, so quality outweighs
  its cost.
- Plan runs on `kimi-coding/k3.1-pro`: a plan is judgment work, and it never
  edits.
- `handoff-review` runs on `openai-codex/gpt-6.2-sol`, read-only: full handoff
  cold reads and run-handoff's final review use it, not ordinary item reviews.
  Those skills allow a per-invocation override and a reported fallback to the
  cheap reviewer when the stronger model is unavailable.

`enabledModels` has one entry per reason to hand-pick; everything else stays in
the picker's all scope.

- `opencode-go/deepseek-v4.1-flash` first, as the default, and
  `opencode-go/*-free` for free Go experiments.
- `kimi-coding/k3.1-pro` for hard work and for work Claude declines.
- Opus and Sonnet on the credit.
- `openai-codex/gpt-6.2-sol` and `openai-codex/gpt-6.1-terra` on the ChatGPT
  plan. pi's bundled catalog ends at GPT-6.1, so 6.2 arrives from the pi.dev
  catalog overlay (`pi update --models`) and is not pinned in `models.json`.
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
- No judge is less private than the actor or the session it reads. An ask from
  a local or TensorX model, or forwarded into a local or TensorX session, skips
  the judge and goes straight to the dialog.
