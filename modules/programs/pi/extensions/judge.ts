/**
 * `judge`: one System One classifier call (TypeSafe Jev) for a question with a
 * fixed answer space, answered with typed values and probabilities instead of
 * prose. It decides, it does not reason, so the facts have to be in `state`
 * before it is asked: this is the tool for "which of these", "does this count
 * as", "how bad is this", not for reading a diff and forming an opinion.
 *
 * The probabilities are the output and the caller decides what they mean; the
 * tool keeps no threshold. Same rule as the architect gate in ./routers.ts: no
 * verdict, or one that does not convince, falls back to what the caller would
 * do without it, never to a guess.
 */
import type { ClassifierAnswer, ClassifierQuestion, Static } from "@earendil-works/pi-ai";
import { Type } from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const PROVIDER = "typesafe";
const MODEL = "jev-latest";
// Jev bills input tokens and a truncated state is a wrong state, so refuse rather than cut.
const MAX_STATE_CHARS = 60_000;

const PARAMS = Type.Object({
  state: Type.Record(Type.String(), Type.Any(), {
    description:
      "The material the questions are about, as named fields. Gather and paste the evidence here first: the classifier cannot look anything up.",
  }),
  questions: Type.Record(
    Type.String(),
    Type.Object({
      type: Type.Union([Type.Literal("choice"), Type.Literal("score"), Type.Literal("bool")], {
        description:
          "choice: one label out of `criteria`. score: a level out of `criteria`. bool: yes or no.",
      }),
      instructions: Type.String({
        description: 'The question itself, e.g. "Is this failure caused by the change under test?"',
      }),
      criteria: Type.Union([Type.Record(Type.String(), Type.String()), Type.Array(Type.String())], {
        description:
          'choice: {label: what it means}, two or more. score: levels lowest first, two or more. bool: {"true": meaning, "false": meaning}.',
      }),
    }),
    {
      description:
        "One or more questions, answered together in a single request. Give each an id; the ids come back as the answer keys.",
    },
  ),
});

type Params = Static<typeof PARAMS>;
type QuestionInput = Params["questions"][string];

const isLevels = (criteria: QuestionInput["criteria"]): criteria is string[] =>
  Array.isArray(criteria);
const isLabels = (criteria: QuestionInput["criteria"]): criteria is Record<string, string> =>
  !Array.isArray(criteria) && typeof criteria === "object" && criteria !== null;

/** Rejects a question whose shape does not match its type here, rather than in the answer. */
function toQuestion(id: string, input: QuestionInput): ClassifierQuestion {
  const { instructions, criteria } = input;
  if (input.type === "score") {
    if (!isLevels(criteria) || criteria.length < 2) {
      throw new Error(`question "${id}": a score needs criteria as an array of two or more levels`);
    }
    return { type: "score", instructions, criteria };
  }
  if (!isLabels(criteria)) {
    throw new Error(`question "${id}": a ${input.type} needs criteria as an object`);
  }
  if (input.type === "bool") {
    if (typeof criteria.true !== "string" || typeof criteria.false !== "string") {
      throw new Error(`question "${id}": a bool needs criteria as {"true": …, "false": …}`);
    }
    return { type: "bool", instructions, criteria: { true: criteria.true, false: criteria.false } };
  }
  if (Object.keys(criteria).length < 2) {
    throw new Error(`question "${id}": a choice needs criteria as {label: meaning}, two or more`);
  }
  return { type: "choice", instructions, criteria };
}

const pct = (p: number) => p.toFixed(2);

/** One line per answer: read against the question the caller wrote, so labels are not repeated. */
function formatAnswer(id: string, answer: ClassifierAnswer, question: ClassifierQuestion): string {
  if (answer.type === "choice") {
    const ranked = Object.entries(answer.probabilities).sort((a, b) => b[1] - a[1]);
    const shown = ranked.length <= 4 ? ranked : ranked.slice(0, 3);
    const rest = ranked.length - shown.length;
    const list = shown.map(([label, p]) => `${label} ${pct(p)}`).join(", ");
    return `${id}: ${answer.choice} (${list}${rest > 0 ? `, +${rest} more` : ""})`;
  }
  if (answer.type === "bool")
    return `${id}: ${answer.probability >= 0.5} (p=${pct(answer.probability)})`;
  const levels = question.type === "score" ? question.criteria : [];
  const max = Math.max(levels.length - 1, 0);
  const nearest = levels[Math.round(answer.score)];
  return `${id}: ${answer.score.toFixed(2)} of ${max}${nearest ? ` (nearest "${nearest}")` : ""}`;
}

const noVerdict = (why: string) => ({
  content: [{ type: "text" as const, text: `No verdict: ${why}. Nothing was judged.` }],
  details: { judged: false, why },
});

export default function (pi: ExtensionAPI) {
  pi.registerTool({
    name: "judge",
    label: "Judge",
    description:
      "Ask a fast decision model (TypeSafe Jev) a question with a fixed answer space and get typed answers with probabilities. Cheap and quick, but it does not reason over evidence: put the facts in `state` first. Read the probabilities instead of trusting the top label; below roughly 0.7 confidence, or a score near the middle, treat it as no verdict and say so.",
    promptSnippet:
      "Typed verdicts from a decision model: choice with probabilities, a rubric score, or yes/no.",
    promptGuidelines: [
      "Use `judge` for a crisp question whose answers you can enumerate (which cause, done or not, how urgent) once the evidence is already in context; use your own reading for anything that needs judgement over evidence.",
      "A `judge` probability under about 0.7 is not a decision: say the verdict was inconclusive rather than presenting it as fact.",
    ],
    parameters: PARAMS,
    async execute(_toolCallId, params, signal, _onUpdate, ctx) {
      const ids = Object.keys(params.questions);
      if (ids.length === 0) throw new Error("judge needs at least one question");
      const questions: Record<string, ClassifierQuestion> = {};
      for (const id of ids) questions[id] = toQuestion(id, params.questions[id]);

      const size = JSON.stringify(params.state).length;
      if (size > MAX_STATE_CHARS) {
        throw new Error(
          `state is ${size} chars, over the ${MAX_STATE_CHARS} limit. Pass only the material the question needs.`,
        );
      }

      const jev = ctx.modelRegistry.findOfType("classifier", PROVIDER, MODEL);
      if (!jev) {
        return noVerdict(
          `no ${PROVIDER}/${MODEL} classifier, which needs TYPESAFE_API_KEY (agent dir: typesafe-api-key)`,
        );
      }

      const result = await ctx.modelRegistry.classify(
        jev,
        { state: params.state, questions },
        { signal },
      );
      if (result.stopReason !== "stop") {
        return noVerdict(result.errorMessage ?? result.stopReason);
      }

      const answered = ids.filter((id) => result.answers[id]);
      const missing = ids.filter((id) => !result.answers[id]);
      const lines = answered.map((id) => formatAnswer(id, result.answers[id], questions[id]));
      if (missing.length > 0) lines.push(`no answer for ${missing.join(", ")}`);
      return {
        content: [{ type: "text" as const, text: lines.join("\n") }],
        details: {
          judged: true,
          model: `${result.provider}/${result.model}`,
          answers: result.answers,
        },
        // The side call never becomes a message, so its cost is only visible here.
        ...(result.usage ? { usage: result.usage } : {}),
      };
    },
  });
}
