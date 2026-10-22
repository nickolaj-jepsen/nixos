/**
 * The frame around pi's editor: the top border names the session, the footer
 * shows the model, spend and git. Modules live in `chrome/`; pi loads only
 * top-level files, so this is the one entry point.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import footer from "./chrome/footer.ts";
import identity from "./chrome/identity.ts";

export default function (pi: ExtensionAPI) {
  identity(pi);
  footer(pi);
}
