/**
 * `ask_user_question`: put one to four structured questions to the user and
 * wait for the answers, so a decision the model cannot make alone comes back
 * as data rather than a conversation.
 *
 * The dialog lives in ./questions/. This file owns the contract: the schema the
 * model fills in, the limits stated in the description, and the non-TUI path.
 *
 * Sequential on purpose. Two questionnaires in the editor slot would replace
 * each other, and pi resolves that by running this tool's calls one at a time.
 */
import { Type } from "@earendil-works/pi-ai";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { QuestionsDialog } from "./questions/dialog.ts";
import {
  HEADER_MAX,
  LABEL_MAX,
  MAX_OPTIONS,
  MAX_QUESTIONS,
  MIN_OPTIONS,
  type Question,
  type QuestionAnswer,
  type QuestionsResult,
  TOOL_NAME,
  TYPE_SOMETHING,
  validateQuestions,
} from "./questions/types.ts";

const DESCRIPTION = `Ask the user 1-4 structured questions, 2-4 options each, and wait for the answers. Never author "Other" or "Type something." options: a "Type something." row and Esc are added to every question. Put a recommended option first and end its label with "(Recommended)". An option's \`preview\` (markdown, single-select only) compares concrete artifacts: mockups, code, diagrams, configs; skip it for plain preferences. The user can select several options when \`multiSelect\` is set.`;

const GUIDELINES = [
  "Use ask_user_question when the request is underspecified and you cannot proceed without a decision; put every question in one call instead of several in a row.",
  `Option labels are 1-5 words and at most ${LABEL_MAX} characters, headers at most ${HEADER_MAX}; longer ones are rejected.`,
];

const OptionSchema = Type.Object({
  label: Type.String({ maxLength: LABEL_MAX, description: "1-5 words; the row the user picks." }),
  description: Type.Optional(Type.String({ description: "One line of context under the label." })),
  preview: Type.Optional(
    Type.String({
      description: "Markdown shown beside the options while this one is highlighted.",
    }),
  ),
});

const QuestionSchema = Type.Object({
  question: Type.String({ description: "The complete question, ending in a question mark." }),
  header: Type.String({
    maxLength: HEADER_MAX,
    description: 'Very short chip naming the question, e.g. "Storage".',
  }),
  options: Type.Array(OptionSchema, { minItems: MIN_OPTIONS, maxItems: MAX_OPTIONS }),
  multiSelect: Type.Optional(
    Type.Boolean({ description: "Let the user pick several options instead of one." }),
  ),
});

/** What the model sees: the answers as a list it can act on, or the refusal. */
export function formatResult(result: QuestionsResult): string {
  if (result.cancelled) {
    return "The user cancelled the questions without answering. Do not treat this as a decision.";
  }
  const lines = ["The user answered:"];
  for (const answer of result.answers) {
    lines.push(`- ${answer.header}: ${answer.values.join(", ")}`);
    if (answer.note) lines.push(`  note: ${answer.note}`);
  }
  return lines.join("\n");
}

/** The TUI dialog, or a sequential walk of the host's own dialogs elsewhere. */
async function ask(
  ctx: ExtensionContext,
  questions: readonly Question[],
  signal: AbortSignal | undefined,
): Promise<QuestionsResult> {
  if (ctx.mode !== "tui") return askSequentially(ctx, questions);
  return ctx.ui.custom<QuestionsResult>(
    (tui, theme, _keybindings, done) => {
      // An interrupted turn takes the dialog with it: the promise must settle or
      // the tool call would hang waiting for an answer nobody can give.
      signal?.addEventListener("abort", () => done({ answers: [], cancelled: true }), {
        once: true,
      });
      return new QuestionsDialog(tui, theme, questions, done);
    },
    { overlay: false },
  );
}

/**
 * RPC, JSON and print hosts get the same answers through their own prompt
 * primitives. A multi-select question is asked repeatedly until the user says
 * Done, which is the only shape those dialogs offer.
 */
async function askSequentially(
  ctx: ExtensionContext,
  questions: readonly Question[],
): Promise<QuestionsResult> {
  const answers: QuestionAnswer[] = [];
  for (const question of questions) {
    const values = question.multiSelect
      ? await askMultiSelect(ctx, question)
      : await askSingle(ctx, question);
    if (values === undefined) return { answers: [], cancelled: true };
    if (values.length > 0) {
      answers.push({ header: question.header, question: question.question, values });
    }
  }
  return { answers, cancelled: false };
}

const prompt = (question: Question) => `${question.header}: ${question.question}`;

async function askSingle(ctx: ExtensionContext, question: Question): Promise<string[] | undefined> {
  const choice = await ctx.ui.select(prompt(question), [
    ...question.options.map((option) => option.label),
    TYPE_SOMETHING,
  ]);
  if (choice === undefined) return undefined;
  if (choice !== TYPE_SOMETHING) return [choice];
  const text = await ctx.ui.input(prompt(question), "Your answer");
  return text?.trim() ? [text.trim()] : [];
}

async function askMultiSelect(
  ctx: ExtensionContext,
  question: Question,
): Promise<string[] | undefined> {
  const picked = new Set<string>();
  for (;;) {
    const entries = question.options.map((option) =>
      picked.has(option.label) ? `✓ ${option.label}` : option.label,
    );
    if (picked.size > 0) entries.push("Done");
    entries.push(TYPE_SOMETHING);
    const choice = await ctx.ui.select(prompt(question), entries);
    if (choice === undefined) return undefined;
    if (choice === "Done") return [...picked];
    if (choice === TYPE_SOMETHING) {
      const text = await ctx.ui.input(prompt(question), "Your answer");
      if (text?.trim()) picked.add(text.trim());
      continue;
    }
    if (picked.has(choice)) picked.delete(choice);
    else picked.add(choice);
  }
}

export default function (pi: ExtensionAPI) {
  pi.registerTool({
    name: TOOL_NAME,
    label: "Ask",
    description: DESCRIPTION,
    promptSnippet: "Ask the user one or more multiple-choice questions.",
    promptGuidelines: GUIDELINES,
    parameters: Type.Object({
      questions: Type.Array(QuestionSchema, { minItems: 1, maxItems: MAX_QUESTIONS }),
    }),
    // One dialog at a time: two would fight over the editor slot.
    executionMode: "sequential",
    async execute(_toolCallId, params, signal, _onUpdate, ctx) {
      const invalid = validateQuestions(params.questions);
      if (invalid) throw new Error(`ask_user_question: ${invalid}`);
      const result = await ask(ctx, params.questions, signal);
      return {
        content: [{ type: "text" as const, text: formatResult(result) }],
        details: result,
      };
    },
  });
}
