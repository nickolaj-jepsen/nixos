# Models in pi

Read this before changing the router (`modules/programs/pi/extensions/core/routers.ts`
and `shared/kinds.ts`), the provider declarations in the pi leaf's `models.json`,
`enabledModels`, or the subagent roles in `modules/programs/pi/agents/`. The
ladders themselves live in `shared/kinds.ts`; this page says why they look the
way they do.

## Subscriptions

- OpenCode Go, $10 a month (moving to $40 when Synthetic ends), runs DeepSeek
  V4.1 Flash, the workhorse. Go is the protected pool: DeepSeek and hand-picked
  Go experiments must never be starved, so no expensive work routes there on its
  own.
- Kimi.ai Pro, $39 a month, serves K3.1 Pro for hard work. Its five-hour window
  is the scarcest resource we have.
- Claude Max 20x stays for the Claude Code app. Its $200 monthly API credit is
  use-it-or-lose-it, so inside pi it costs nothing at the margin, and it is
  spent before Go on anything expensive.
- Synthetic is paid through 2026-11-23 and stays in the ladders until then. A
  dated commit then removes its provider, catalog, secret and stages, and Go
  moves to the $40 plan.
- TensorX (EU, zero retention) and local models are for data-sensitive work,
  picked by hand and never routed to. `_tensorx-models.nix` holds only the
  models sessions actually pick; it is not kept in sync with opencode's list.

## The virtual models

`vm/flash` drives ordinary turns and every delegated role but Plan. Its last
stage is Sonnet on the credit rather than Haiku, since the credit is free until
its floor anyway.

`vm/deep` is for hard work: the prepaid Kimi plan first, then Opus while the
credit lasts. It has no Go stage, so when its pools are out the turn fails
loudly instead of draining the protected pool. Go's K3.1 Pro is a hand-pick.

`vm/architect` asks Jev (typesafe's classifier) how hard each planning prompt
is. Complex prompts plan on the deep ladder, standard ones on flash, and no
verdict means deep. The first successful edit (codemode's nested edits count)
hands the rest to flash; `/replan` sends the next prompt back to planning.

## Routing rules

- The credit has a fixed $20 floor (`CREDIT_RESERVE_USD`) and nothing else
  limits how fast it goes. A pace guard would only push the overflow onto Go.
  Hand-picked Opus is never restricted.
- A pool is out while ai-usage reports a used-up window. A provider's own limit
  error, which pi does not retry, blocks it too: until the window's reset once
  ai-usage sees it, and for 10 minutes while ai-usage lags. The router then
  continues the interrupted turn on the next pool before the run settles.
- A Go timeout, overload or stream-ended error sends that one retry a stage
  down. The pool is not blocked, and the next request goes back to Go: these
  errors come in short bursts.
- Synthetic's weekly meter keeps a 10% reserve, so a turn never ends on a hard
  429 that no pool can cover.
- Background requests such as compaction try the credit stage last.
- `/vm` shows each pool's windows and blocks, the credit with this session's
  spend from the usage ledger, and the last routes with why stages were skipped.

## Jev

The gate is an experiment. Every verdict is stored as a `vm-jev` custom entry
(prompt hash, verdict, latency, the ladder that ran) so it can later be compared
against a DeepSeek classifier. It comes up at the 2026-11-07 usage review.

## Roles and enabledModels

Every subagent role locks its model; none inherits the parent's, because
inheritance once ran cheap children on Opus. Explore, general-purpose, reviewer
and verifier run on `vm/flash`. Plan runs on `vm/architect`: it has no edit
tool, so it never leaves planning, and Jev rates the parent's brief once to put
the whole run on deep or flash.

`enabledModels` has one entry per reason to hand-pick: `vm/*` for the tiers,
Opus and Sonnet on the credit, `kimi-coding/k3.1-pro` for work Claude declines,
`opencode-go/*` for Go experiments, and `tensorx/**` plus `local/*` for
sensitive work. Everything else stays in the pickers' All tab.

## Sensitive and declined work

`vm/deep` contains Opus, and a Claude refusal looks like a finished turn, so it
cannot be the escape hatch for work a Claude model declines. That work goes to
`kimi-coding/k3.1-pro` by hand, and data-sensitive work to local or TensorX.
Dedicated cyber tiers are deferred.

## Guardian

`guardian.ts` asks one judge, picked from the physical model that made the tool
call, so a `vm/*` failover counts as the model it failed over to. The judge is
never from the actor's family (`judgeFor`): Sonnet judges DeepSeek, DeepSeek
judges everyone else. No judge is less private than the actor: a local or
TensorX session's asks skip the judge and go straight to the dialog.
