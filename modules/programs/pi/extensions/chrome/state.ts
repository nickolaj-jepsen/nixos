import type { ExtensionContext } from "@earendil-works/pi-coding-agent";

export type Renderer = { requestRender(): void };
export type Action = (ctx: ExtensionContext) => void | Promise<void>;

/** State shared by the chrome modules; one instance per extension load. */
export type ChromeState = {
  ctx: ExtensionContext | undefined;
  tui: Renderer | undefined;
  /** pi copies its app keybinding handlers onto a CustomEditor, so clicks can reuse them. */
  editor: { actionHandlers?: Map<string, () => void> } | undefined;
  /** Whether the last editor render drew the context gauge; the footer shows context while false. */
  gaugeActive: boolean;
};

export const createState = (): ChromeState => ({
  ctx: undefined,
  tui: undefined,
  editor: undefined,
  gaugeActive: false,
});
