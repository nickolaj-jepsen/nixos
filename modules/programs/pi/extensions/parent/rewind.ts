/**
 * `/rewind`: go back to a question the agent asked and answer it again.
 *
 * The dialog reopens on the answers given the first time, and the branch goes
 * back to that question's answer, so the work that followed leaves the way (it
 * stays on its branch, reachable with `/tree`) instead of arguing with the new
 * answer. The next turn then starts from it.
 *
 * The model is told twice on purpose: the stored answer is rewritten in the
 * request the `context` hook builds, and the message that starts the turn says
 * what changed, for the transcript a person reads. Only the request is
 * rewritten: the session file keeps the answer it was given, so compaction and
 * exports still read that one.
 */
import { Box, Text } from "@earendil-works/pi-tui";
import type { AgentMessage } from "@earendil-works/pi-agent-core";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { answerLines, askQuestions, formatResult } from "./questions.ts";
import { type Question, type QuestionAnswer, TOOL_NAME } from "./questions/types.ts";
import { clip } from "../shared/naming.ts";

/** The message type that starts the turn after a rewind and records the answers. */
const MESSAGE_TYPE = "rewind.answers";

const LABEL_CHARS = 120;

interface RewindDetails {
  /** The call whose answer is replaced, so the `context` hook can find it. */
  readonly toolCallId: string;
  readonly answers: readonly QuestionAnswer[];
}

/** One question round the model asked and the user answered, on this branch. */
interface PastQuestion {
  /**
   * Where the branch goes back to: the batch's last tool result. A turn that
   * asked while it also called other tools declared all of them in one message,
   * so the branch has to end after every result of that message or the request
   * carries a call it never answered.
   */
  readonly rewindEntryId: string;
  readonly toolCallId: string;
  readonly questions: readonly Question[];
  readonly answers: readonly QuestionAnswer[];
}

const isQuestion = (value: unknown): value is Question => {
  const question = value as Partial<Question> | undefined;
  return (
    typeof question?.question === "string" &&
    typeof question.header === "string" &&
    Array.isArray(question.options)
  );
};

/** The questions a call asked, when it can be shown again as it was. */
const questionsOf = (args: unknown): Question[] | undefined => {
  const questions = (args as { questions?: unknown } | undefined)?.questions;
  if (!Array.isArray(questions) || questions.length === 0) return undefined;
  return questions.every(isQuestion) ? questions : undefined;
};

const isAnswer = (value: unknown): value is QuestionAnswer => {
  const answer = value as Partial<QuestionAnswer> | undefined;
  return (
    typeof answer?.header === "string" &&
    typeof answer.question === "string" &&
    Array.isArray(answer.values) &&
    answer.values.every((picked) => typeof picked === "string")
  );
};

/** The answers a stored result holds, when it holds any this version can read. */
const answersIn = (details: unknown): QuestionAnswer[] => {
  const answers = (details as { answers?: unknown } | undefined)?.answers;
  return Array.isArray(answers) ? answers.filter(isAnswer) : [];
};

/**
 * The question rounds on the active branch, oldest first, with the answers that
 * count: a round re-answered before reads back the newer answers.
 *
 * A round is only listed once its call has a result: without one there is
 * nothing to rewind to, and nothing the model was told. A rejected call is
 * left out: it asked nothing the user could answer.
 */
function pastQuestions(
  ctx: ExtensionContext,
  rewrites: ReadonlyMap<string, readonly QuestionAnswer[]>,
): PastQuestion[] {
  // Which assistant message declared a call, and the last result of each of those messages.
  const batchOf = new Map<string, string>();
  const lastResult = new Map<string, string>();
  const questionsOfCall = new Map<string, Question[]>();
  const results: { toolCallId: string; details: unknown }[] = [];
  for (const entry of ctx.sessionManager.getBranch()) {
    if (entry.type !== "message") continue;
    const message = entry.message;
    if (message.role === "assistant") {
      for (const block of message.content) {
        if (block.type !== "toolCall") continue;
        batchOf.set(block.id, entry.id);
        if (block.name !== TOOL_NAME) continue;
        const questions = questionsOf(block.arguments);
        if (questions) questionsOfCall.set(block.id, questions);
      }
      continue;
    }
    if (message.role !== "toolResult") continue;
    const batch = batchOf.get(message.toolCallId);
    if (batch) lastResult.set(batch, entry.id);
    if (message.toolName !== TOOL_NAME || message.isError) continue;
    results.push({ toolCallId: message.toolCallId, details: message.details });
  }

  const found: PastQuestion[] = [];
  for (const result of results) {
    const questions = questionsOfCall.get(result.toolCallId);
    const batch = batchOf.get(result.toolCallId);
    const rewindEntryId = batch === undefined ? undefined : lastResult.get(batch);
    if (!questions || rewindEntryId === undefined) continue;
    // Cancelled rounds count: coming back to one is how a user changes a refusal.
    found.push({
      rewindEntryId,
      toolCallId: result.toolCallId,
      questions,
      answers: rewrites.get(result.toolCallId) ?? answersIn(result.details),
    });
  }
  return found;
}

const clock = (iso: string) =>
  new Date(iso).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });

/** One row per round: when, what was asked, and what it was answered. */
function label(past: PastQuestion, at: string): string {
  const [first] = past.questions;
  const more = past.questions.length > 1 ? ` +${past.questions.length - 1}` : "";
  const said = past.answers.length
    ? past.answers.map((answer) => answer.values.join(", ")).join("; ")
    : "cancelled";
  return `${clock(at)} ${first?.header ?? "?"}${more} · ${first?.question ?? ""} — ${said}`;
}

/** The same answers, question for question, whether or not anything moved. */
const unchanged = (before: readonly QuestionAnswer[], after: readonly QuestionAnswer[]) =>
  before.length === after.length &&
  before.every((answer, index) => {
    const other = after[index];
    return (
      other !== undefined &&
      answer.header === other.header &&
      answer.values.join("\u0000") === other.values.join("\u0000") &&
      (answer.note ?? "") === (other.note ?? "")
    );
  });

const content = (answers: readonly QuestionAnswer[]) =>
  [
    "The user re-answered the questions above. These answers replace the ones you were given:",
    ...answerLines(answers),
    "",
    "Continue from them. Work done after the earlier answer is not undone, so check what is already",
    "in place before acting on the difference.",
  ].join("\n");

const reason = (error: unknown) => (error instanceof Error ? error.message : String(error));

export default function (pi: ExtensionAPI) {
  /**
   * The answers that replace a call's result, by tool call id. Rebuilt from the
   * branch so a reload, a resume or a step back in `/tree` puts it right.
   */
  const rewrites = new Map<string, readonly QuestionAnswer[]>();

  const rebuild = (ctx: ExtensionContext) => {
    rewrites.clear();
    for (const entry of ctx.sessionManager.getBranch()) {
      if (entry.type !== "custom_message" || entry.customType !== MESSAGE_TYPE) continue;
      const details = entry.details as RewindDetails | undefined;
      if (details?.toolCallId) rewrites.set(details.toolCallId, details.answers.filter(isAnswer));
    }
  };

  pi.on("session_start", (_event, ctx) => rebuild(ctx));
  pi.on("session_tree", (_event, ctx) => rebuild(ctx));

  // The answer the model reads is the one stored, unless it was re-answered.
  pi.on("context", (event) => {
    if (rewrites.size === 0) return;
    let replaced = false;
    const messages = event.messages.map((message): AgentMessage => {
      if (message.role !== "toolResult") return message;
      const answers = rewrites.get(message.toolCallId);
      if (!answers) return message;
      replaced = true;
      return {
        ...message,
        content: [{ type: "text" as const, text: formatResult({ answers, cancelled: false }) }],
      };
    });
    return replaced ? { messages } : undefined;
  });

  pi.registerMessageRenderer<RewindDetails>(MESSAGE_TYPE, (message, { outputPad }, theme) => {
    const answers = message.details?.answers ?? [];
    const lines = ["↩ Re-answered an earlier question", ...answerLines(answers)];
    const box = new Box(outputPad, 0);
    box.addChild(new Text(theme.fg("accent", lines[0] ?? ""), 0, 0));
    box.addChild(new Text(theme.fg("text", lines.slice(1).join("\n")), 0, 0));
    return box;
  });

  pi.registerCommand("rewind", {
    description: "Answer an earlier question again, rewinding to it",
    handler: async (_args, ctx) => {
      if (ctx.mode !== "tui") {
        ctx.ui.notify("/rewind needs the terminal UI.", "info");
        return;
      }
      // A rewind changes the branch, which a running turn is reading from.
      if (!ctx.isIdle()) {
        ctx.ui.notify("Wait for the current turn to finish.", "info");
        return;
      }
      const rounds = pastQuestions(ctx, rewrites);
      if (rounds.length === 0) {
        ctx.ui.notify("No answered questions on this branch to rewind to.", "info");
        return;
      }
      // Later rounds are nearer the end, which is where a second look usually goes.
      const choices = [...rounds].reverse().map((past, position) => {
        const at = ctx.sessionManager.getEntry(past.rewindEntryId)?.timestamp ?? "";
        return { past, row: `${rounds.length - position}. ${clip(label(past, at), LABEL_CHARS)}` };
      });
      const picked = await ctx.ui.select(
        "Rewind to a question? The turns after it move to /tree.",
        choices.map((choice) => choice.row),
      );
      if (picked === undefined) return;
      const past = choices.find((choice) => choice.row === picked)?.past;
      if (!past) return;
      const answered = await askQuestions(ctx, past.questions, ctx.signal, past.answers);
      if (answered.cancelled) return;
      if (unchanged(past.answers, answered.answers)) {
        ctx.ui.notify("The answers are unchanged.", "info");
        return;
      }
      const navigated = await (async () => {
        try {
          // A peer message or a finished job can start a turn while the dialog is open,
          // and navigating a moving session throws.
          await ctx.waitForIdle();
          return await ctx.navigateTree(past.rewindEntryId, { summarize: false });
        } catch (error) {
          ctx.ui.notify(`Rewind failed, answers not applied: ${reason(error)}`, "error");
          return undefined;
        }
      })();
      if (navigated === undefined) return;
      if (navigated.cancelled) {
        ctx.ui.notify("The rewind was cancelled, so your answers were not applied.", "info");
        return;
      }
      const details: RewindDetails = { toolCallId: past.toolCallId, answers: answered.answers };
      rewrites.set(past.toolCallId, answered.answers);
      pi.sendMessage<RewindDetails>(
        { customType: MESSAGE_TYPE, content: content(answered.answers), display: true, details },
        { triggerTurn: true },
      );
    },
  });
}
