/**
 * The prompt's editor, assembled from every extension that has a say in it:
 * spellfix supplies one (its highlighting), chrome wraps it (the border).
 *
 * pi accepts one editor factory, so the extensions have to compose rather than
 * each install theirs. Composing on registration is also the only order that
 * works: `session_start` handlers run one after another and await in between,
 * so an install deferred with a timer lands in the middle of the pass and the
 * next handler's install silently replaces it.
 *
 * Register a wrapper once from the extension factory, but install from a
 * `session_start` handler (`providePromptEditor` or `ensurePromptEditor`) — never
 * from the factory itself, since some invocations never start a session.
 */
import {
  CustomEditor,
  type ExtensionContext,
  type ExtensionUIContext,
} from "@earendil-works/pi-coding-agent";

// pi's root types omit EditorFactory, so it comes from the one API that takes it.
type EditorFactory = NonNullable<Parameters<ExtensionUIContext["setEditorComponent"]>[0]>;

type Editor = ReturnType<EditorFactory>;
type Host = Parameters<EditorFactory>;

/** Draws around the editor it is handed; wrappers nest, so a later one draws outermost. */
export type EditorWrapper = (inner: Editor, host: Host) => Editor;

type Chain = {
  ctx?: ExtensionContext;
  /** The editor to wrap; another extension's factory when nothing provided one. */
  inner?: EditorFactory;
  wrappers: EditorWrapper[];
  /** The factory this chain last installed; anything else in the slot came from elsewhere. */
  installed?: EditorFactory;
};

const chain: Chain = { wrappers: [] };

const compose = (): EditorFactory => {
  const { inner, wrappers } = chain;
  return (tui, theme, keybindings) => {
    const host: Host = [tui, theme, keybindings];
    const editor = inner
      ? inner(...host)
      : new CustomEditor(tui, theme, keybindings, { embedWorkingStatus: true });
    return wrappers.reduce<Editor>((wrapped, wrap) => wrap(wrapped, host), editor);
  };
};

/**
 * Puts a composed factory in the slot, rebuilding the editor only when the chain
 * changed (`recomposed`), the slot was empty, or another extension took it.
 */
const install = (recomposed: boolean) => {
  const { ctx } = chain;
  if (!ctx || ctx.mode !== "tui" || !ctx.hasUI) return;
  const current = ctx.ui.getEditorComponent();
  const foreign = current !== chain.installed;
  if (foreign) chain.inner = current;
  if (!recomposed && !foreign && chain.installed !== undefined) return;
  const factory = compose();
  chain.installed = factory;
  ctx.ui.setEditorComponent(factory);
};

/** Adds a wrapper for every editor installed from now on; register each one once. */
export const wrapPromptEditor = (wrapper: EditorWrapper) => {
  chain.wrappers.push(wrapper);
};

/** Supplies the editor the wrappers draw around. */
export const providePromptEditor = (ctx: ExtensionContext, factory: EditorFactory) => {
  chain.ctx = ctx;
  chain.inner = factory;
  install(true);
};

/** Takes the slot, or takes it back when another extension installed its own factory. */
export const ensurePromptEditor = (ctx: ExtensionContext) => {
  chain.ctx = ctx;
  install(false);
};
