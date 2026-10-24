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
 * Everything here belongs to the live TUI session. Provide or wrap from its
 * `session_start`, never from the extension factory: pi re-runs a cached
 * factory for /new, /resume, /fork, /reload and in-process subagents. Withdraw
 * and unwrap at its `session_shutdown`, so the next session's editor never
 * draws through a disposed session's ctx.
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
  /** The editor `providePromptEditor` supplied. */
  provided?: EditorFactory;
  /** Another extension's factory found in the slot, wrapped in place of `provided`. */
  adopted?: EditorFactory;
  wrappers: Map<string, EditorWrapper>;
  /** The wrappers changed since the last install. */
  stale: boolean;
  /** The factory this chain last installed. */
  installed?: EditorFactory;
  /** Every factory this chain installed, so none is mistaken for another extension's. */
  own: WeakSet<EditorFactory>;
};

// On globalThis because each extension loads its own copy of this module, and
// all of them must compose on one chain.
const KEY = Symbol.for("fireproof.pi.prompt-editor");
const store = globalThis as { [KEY]?: Chain };
const chain: Chain = (store[KEY] ??= { wrappers: new Map(), stale: false, own: new WeakSet() });

const compose = (): EditorFactory => {
  const inner = chain.adopted ?? chain.provided;
  const wrappers = [...chain.wrappers.values()];
  return (tui, theme, keybindings) => {
    const host: Host = [tui, theme, keybindings];
    const editor = inner
      ? inner(...host)
      : new CustomEditor(tui, theme, keybindings, { embedWorkingStatus: true });
    return wrappers.reduce<Editor>((wrapped, wrap) => wrap(wrapped, host), editor);
  };
};

const install = (ctx: ExtensionContext) => {
  const factory = compose();
  chain.installed = factory;
  chain.own.add(factory);
  chain.stale = false;
  ctx.ui.setEditorComponent(factory);
};

const live = (ctx: ExtensionContext) => ctx.mode === "tui" && ctx.hasUI;

/** Puts `wrapper` under `key`, replacing what the key held, from the next install on. */
export const wrapPromptEditor = (key: string, wrapper: EditorWrapper) => {
  chain.wrappers.set(key, wrapper);
  chain.stale = true;
};

/** Removes `wrapper` if `key` still holds it, from the next install on. */
export const unwrapPromptEditor = (key: string, wrapper: EditorWrapper) => {
  if (chain.wrappers.get(key) !== wrapper) return;
  chain.wrappers.delete(key);
  chain.stale = true;
};

/** Supplies the editor the wrappers draw around, in place of whatever holds the slot. */
export const providePromptEditor = (ctx: ExtensionContext, factory: EditorFactory) => {
  if (!live(ctx)) return;
  chain.provided = factory;
  chain.adopted = undefined;
  install(ctx);
};

/** Drops `factory` if it is still the one provided, from the next install on. */
export const withdrawPromptEditor = (factory: EditorFactory) => {
  if (chain.provided === factory) chain.provided = undefined;
};

/**
 * Takes the slot, rebuilding the editor only when the wrappers changed, the
 * slot was emptied, or another extension installed its own factory, which is
 * then wrapped instead.
 */
export const ensurePromptEditor = (ctx: ExtensionContext) => {
  if (!live(ctx)) return;
  const current = ctx.ui.getEditorComponent();
  if (current !== undefined && current === chain.installed && !chain.stale) return;
  if (current === undefined || !chain.own.has(current)) chain.adopted = current;
  install(ctx);
};
