---
name: mine
description: Answer a question or complaint about how your agents have been working, from your past Claude Code and pi sessions, then improve the skill, tool, CLI, hook, agent instructions or harness behind it.
disable-model-invocation: true
argument-hint: "<question, complaint or target>"
metadata:
  status: in-progress
---

The user has a hunch or a complaint about how their agents have been working, and the past transcripts hold the evidence: "the hub keeps announcing the wrong state", "why is it lazier in this repo?", "how well do the mod tools work?". Find out whether it's true, what causes it and what to change, then help change it.

- The arguments are the question, in the user's words. They may name a target, a symptom, a repo or only a feeling. Say in a line what you take the question to be and which evidence you'll read, then go. Don't bend it into the nearest skill or tool when it's about something wider.
- A bare name ("ideate") means: how has this been going, and what would improve it?
- With no arguments, ask what to look at.
- For one session, usually the current one, use `/retro`.

## Evidence

`python3 <skill-dir>/scripts/sessions.py` (substitute this skill directory's absolute path) reads Claude Code, its work profile and pi transcripts, read-only. `--help` has every flag. Each call scans every session, so it takes seconds to a minute.

- `runs <matchers> [--since DATE] [--show IDS|all]`: a signal header, then one line per run of a skill, tool or command. `--show` prints runs condensed.
- `work --path SUBSTR [--mention REGEX]`: your typed turns in the recent sessions that edited or discussed something. It shows what was decided and why, and the complaints already made.
- `prompts [--cwd SUBSTR] [--grep REGEX] [--since DATE]`: the first prompt of every session, for questions about a repo or a kind of work that no matcher covers.
- `session <id>`: one whole session condensed.

Matchers, by what the question is about:

- A skill: `--skill <name>`. A run lasts until another skill is invoked, so it often includes later work, and its error counts are pointers. `via` says whether it was typed or the model reached for it, `body` which copy ran, `ver` which commit's text.
- A pi extension or tool: one `--tool` per tool name it registers (read its source). The header says how many sessions offered the tool and how many called it. Offered and never called is a description problem.
- A CLI: `--cmd <binary>`, plus `--tool` for a harness tool that wraps it. `--help` calls and an error followed by a retry point at discoverability.
- A hook, a setting or a symptom: `--text <regex>` on its distinctive output, such as a block message. A blocked call followed by a rephrased retry of the same intent is probably a false positive, and the same denial repeating suggests a missing allow rule.
- A skill that asks questions: the header splits answers into recommended, other, custom and so on. A question nearly always answered with the recommendation is a decision to state instead of ask. One often answered custom is missing an option. One where another option often wins has the wrong recommendation.

Transcripts are rarely the only evidence, and often not the fastest:

- The target's own logs, source and docs. Read the docs page the repo's agent instructions point to before judging a system.
- Its git history: when every run behind a problem predates the latest change, it may already be fixed.
- Memories that mention it, which are corrections someone already wrote down.
- A baseline. "Is it this repo?" or "is it this skill?" needs the same number from elsewhere before it means anything.
- Prior art, when the user asks for it or the right approach is open.

## Reading many runs

With a handful of runs, read them yourself with `--show`. With more, take the most recent, keep a few from each version, and say how many you left unread. Hand batches of about eight to fresh subagents on a cheaper model (`model: "sonnet"` in Claude Code; pi's roles already lock one), and say how many you're starting.

Give each one the question, its run ids, the reader command to run itself and the privacy rules below. Ask for notes in its reply and no files. Per run, what's worth asking for: the first point where it went worse than it should have, with its turn number, or "clean"; what the user did once the target's part was done; and what went wrong that wasn't the target's fault.

A correction is the user redirecting, repeating themselves, rejecting an approach or interrupting. "Yes", "no" and a letter in an interview are answers.

## From evidence to changes

- Count. "7 of 20 runs" with their session ids is a finding, and one run is an anecdote: mention it, don't build on it. Rank by how many runs something hit and what it cost the user in corrections, interrupts and abandoned runs.
- Look for desire paths as well as failures. A follow-up most runs share is a step the target could offer itself, and a tool-call sequence the agent works out again each time is a script to bundle.
- Fix it where the cause is: the target's own text or scripts; the harness or an extension, through its extension points instead of patches to its built-ins; agent instructions or memory; the repo; the environment. A cause shared with other targets is not a fix to this one.
- Prefer the cheapest change that holds, in roughly this order. Cutting or correcting the text that asked for the behaviour is nearly free. A tool or error message changed so the failure can't happen holds without anyone remembering it. A check or hook comes next, when the rule has no legitimate exceptions. New prose is last: every later session pays for it in context, and it is the first thing ignored. A rule that exists and keeps being broken needs a stronger level, and restating it louder won't help.
- `work` shows earlier decisions. They are context, and when a change reverses one, say so.

## Reply

Answer the question first, in plain words, including "no, the data doesn't show that" when that's the answer. Then the findings, most consequential first, each with its count, a line of evidence and the change you'd make, and the one you'd start with. Use whatever shape fits the question, and say what you didn't read.

Ask the user only what would change the conclusion, such as a run you can't interpret. Don't ask them to confirm labels or groupings.

Then do what they say with it: build the picks in this session and run the repo's checks, look into the open ones, or hand a finding to another skill when they name one. Commit by the repo's own rules.

Findings that won't all be handled in this session are worth a note: `findings/<target>.md` in the store of the project the target belongs to (the checkout sees the store as `.agents/store`), never committed, with each finding's evidence, change and status. When that file already exists this is a rerun: read it first, pass `--since <its date>` and update it in place.

## Privacy

Transcripts are private.

- Condensed transcript text never goes to disk. A findings note holds counts, session ids and a short quote or paraphrase.
- Never quote a secret, and quote a phrase rather than a passage. Runs marked work profile, and memories under `~/.claude-work/`, are paraphrased, never quoted.
- A subagent's brief repeats these rules and names runs by id instead of pasting transcript text.
