import { clean } from "./monitor-row.js";

/** An agent's session name, from its terminal title, or "" when the title is not one:
 *  its program's own name ("Claude Code"), or a folder (Pi's "~/dev/x · 2m", "π - x"). */
export function agentName(agent) {
  const title = clean(agent?.title);
  const pi = /^π - (.+) - [^-]+$/.exec(title);
  if (pi) return pi[1].trim();
  if (!title || /^[~/]|^π - /.test(title)) return "";
  // Claude prefixes its title with a spinner or "✳" while it works.
  const name = title.replace(/^[^\p{L}\p{N}]+/u, "");
  return name === agent.program?.name || name === agent.app ? "" : name;
}
