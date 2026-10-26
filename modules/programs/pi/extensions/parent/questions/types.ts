/**
 * The questionnaire's contract with the model: what a call may contain and
 * what comes back. Kept apart from the dialog so the limits the model is told
 * about in `questions.ts` and the ones enforced here are the same numbers.
 */

export const TOOL_NAME = "ask_user_question";

/** Limits, also stated to the model in the tool description. */
export const MAX_QUESTIONS = 4;
export const MAX_OPTIONS = 4;
export const MIN_OPTIONS = 2;
export const HEADER_MAX = 16;
export const LABEL_MAX = 60;

/** The always-present row for an answer the options do not cover. */
export const TYPE_SOMETHING = "Type something.";

export interface QuestionOption {
  readonly label: string;
  readonly description?: string;
  /** Markdown shown beside the options while this one is highlighted. */
  readonly preview?: string;
}

export interface Question {
  readonly question: string;
  readonly header: string;
  readonly options: readonly QuestionOption[];
  readonly multiSelect?: boolean;
}

/** One answered question, flattened for the tool result. */
export interface QuestionAnswer {
  readonly header: string;
  readonly question: string;
  readonly values: readonly string[];
  /** What the user added beside the answer, when they did. */
  readonly note?: string;
}

export interface QuestionsResult {
  readonly answers: readonly QuestionAnswer[];
  readonly cancelled: boolean;
}

/**
 * Every reason a call cannot be rendered, in one message.
 *
 * All findings are reported at once: a model that has to fix a header and a
 * label should not need two round trips to hear about both.
 */
export function validateQuestions(questions: readonly Question[]): string | undefined {
  const problems: string[] = [];
  if (questions.length === 0) problems.push("ask at least one question");
  if (questions.length > MAX_QUESTIONS) problems.push(`ask at most ${MAX_QUESTIONS} questions`);
  questions.forEach((question, index) => {
    const at = `question ${index + 1}`;
    if (question.header.length > HEADER_MAX) {
      problems.push(
        `${at}: header is ${question.header.length} characters, the limit is ${HEADER_MAX}`,
      );
    }
    if (question.options.length < MIN_OPTIONS || question.options.length > MAX_OPTIONS) {
      problems.push(`${at}: give ${MIN_OPTIONS}-${MAX_OPTIONS} options`);
    }
    question.options.forEach((option, optionIndex) => {
      if (option.label.length > LABEL_MAX) {
        problems.push(
          `${at}, option ${optionIndex + 1}: label is ${option.label.length} characters, the limit is ${LABEL_MAX}`,
        );
      }
      if (option.preview !== undefined && question.multiSelect) {
        problems.push(`${at}, option ${optionIndex + 1}: previews need a single-select question`);
      }
    });
  });
  return problems.length > 0 ? problems.join("; ") : undefined;
}
