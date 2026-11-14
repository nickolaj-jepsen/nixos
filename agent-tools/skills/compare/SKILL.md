---
name: compare
description: Research a choice between tools, libraries, services or products and say which to pick, whether the user's current one still holds, or whether to build. Takes a named field, an open category or a question like "has this space moved". --quick answers inline from a few searches.
disable-model-invocation: true
argument-hint: "<candidates, category or question> [--quick]"
---

The user is choosing between things, or wondering whether a better one exists, and wants an answer they can act on, backed by evidence they can check. The job is to find out what the options really are, weigh them against what the user needs, and say which to take. This skill changes no code and writes nothing outside `/tmp`.

- The arguments are the question, in the user's words, and they come in different shapes. "Has this space moved?" wants a survey anchored on what they use today, ending in whether to move. "What are my options for X?" wants options measured against the requirements they listed. "A vs B" wants a head-to-head. Say in a line what you take the question, the purpose and the requirements to be, so they can object, then go.
- Requirements the user wrote or confirmed are the must-haves. Ones you inferred from their setup or from memory are priorities, and you say so. Ask first only when one unknown could flip the answer, and ask only that.
- `--quick` is the light end: a few searches inline, a short verdict, no subagents. Without it, scale effort to the ask: a casual question gets a short run, a decision with real cost riding on it gets the full treatment below.
- With no arguments, ask what the choice is.

## The field

- The incumbent is always a candidate, and "keep what you have" is a legitimate verdict. Add "build our own" only when the scope makes it plausible, such as a plugin, a script or a fork, never for a framework or a product category.
- For an open category, sweep for what exists, newcomers included, before narrowing. A big sweep can go to one fresh subagent that returns a deduplicated list with a line and a link each.
- Drop a candidate only on a clear fail of a must-have with a source, and say what was dropped and why in a line. A must-have you can't check cheaply leaves the candidate in, marked unverified.
- When you narrow a large field, narrow on the requirements in the user's own words. A list you drafted for them tends to miss the one they care most about.

## Priorities by kind of field

Starting points for what to weigh among the survivors, in this order unless the user says otherwise.

- **Software tool or library:** fit for the purpose, critical mass (stars, contributors, downloads, dependents), maintenance (release cadence, recent commits, bus factor), licence and forkability, platforms and packaging, cost in context or resources where agents use it.
- **Hosted service or subscription:** what the limits really are in use, price at the user's volume, ToS (custom clients, agents), data retention and jurisdiction, lock-in and export.
- **Physical product:** local availability and price with shipping, compatibility with what they own, reviews from long-term owners. For a user in Denmark, `../pricerunner/SKILL.md` beside this skill's directory gives prices: read it and run its script, because it is user-invoked only and can't be invoked as a skill.

## Evidence

These rules hold at any effort, because a comparison is only as good as its sources.

- Every claim has a source link and an as-of date. Prefer the strongest source: the code or the published package over docs, docs over README claims, README claims over third-party write-ups. A claim that rests only on a README or marketing page is marked "claimed".
- Prior knowledge goes stale on exactly what decides these choices: prices, limits, versions, maintenance status, licences. Look them up.
- When docs and user reports (issue trackers, forums, changelogs) disagree, report both.
- Measure what can be measured cheaply in a sandbox under `/tmp`: install it with a one-off package command, time a run, count tokens, run a few benchmark queries. Measure the thing the claim is about, not a proxy. A number you didn't measure is "claimed", with the command that would measure it.
- When a source contradicts what the user said, carry it to them as a conflict ("docs say X; you said Y; users report Z") and never settle it in the docs' favour.

## Subagents, for a real head-to-head

When a decision rides on it, one fresh subagent per finalist, in parallel, pays off. Each sees only its own candidate, so the order of the field and the first-named option can't sway it. Use a fresh agent, not a fork, because a fork inherits your leanings. Give each the same criteria sheet (purpose, must-haves, priorities in order, today's date, the evidence rules above), ask for every row answered or marked unknown, and for the candidate's strongest case and worst problem in a sentence each.

A verifier afterwards, also fresh, tries to refute the cells: does each source exist and say that, does each measurement measure what its claim says, is the evidence comparable across candidates (a code reference for one and a README line for another is not). It returns cells as confirmed, refuted with the correction, or unverified. Overrule it only with evidence, and say so.

Skip both for a casual question, a small field or a quick run. Without a subagent tool, research candidates one after another, finishing one before reading about the next. Keep the findings in context, so a follow-up is answered from them before searching again.

## Reply

Open with the verdict: pick, keep, build or wait. Then why, naming the decisive rows, and the ranking argued in prose. No numeric scores or weights.

For a head-to-head, a table is the right shape: rows by priority, each cell a short claim with its source, gaps and unverified cells marked as such, and columns that follow the candidates. Say what was dropped and why, list conflicts for the user to settle, and give "flip if" lines (if X matters more than Y, pick Z). A survey or an options question can be shorter and need no table. Use whatever fits. End on the next step the user can take, such as building it, or `/compare` without `--quick` for a deeper run.
