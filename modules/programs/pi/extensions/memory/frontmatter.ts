/**
 * The frontmatter dialect memory files use: one `key: value` per line, where a
 * value is JSON when it parses as JSON and a bare string otherwise. Every value
 * written is valid YAML, so editors and `yq` read the files, and a hand-edited
 * bare string survives without quoting.
 */

export type FrontmatterValue =
  | string
  | number
  | boolean
  | null
  | FrontmatterValue[]
  | { [key: string]: FrontmatterValue };

export type Parsed = { data: Record<string, FrontmatterValue>; body: string };

const FENCE = "---";

/** Splits `text` into frontmatter and body; a file without a leading fence is all body. */
export function parse(text: string): Parsed {
  const lines = text.replace(/\r\n/g, "\n").split("\n");
  if (lines[0] !== FENCE) return { data: {}, body: text.trim() };
  const end = lines.indexOf(FENCE, 1);
  if (end === -1) return { data: {}, body: text.trim() };
  const data: Record<string, FrontmatterValue> = {};
  for (const line of lines.slice(1, end)) {
    const match = /^([A-Za-z_][\w-]*):\s?(.*)$/.exec(line);
    if (!match) continue;
    data[match[1]] = value(match[2].trim());
  }
  return {
    data,
    body: lines
      .slice(end + 1)
      .join("\n")
      .trim(),
  };
}

function value(raw: string): FrontmatterValue {
  if (raw === "" || raw === "~" || raw === "null") return null;
  try {
    return JSON.parse(raw) as FrontmatterValue;
  } catch {
    // YAML-style quoting an editor may have added.
    if (raw.length >= 2 && raw.startsWith("'") && raw.endsWith("'"))
      return raw.slice(1, -1).replace(/''/g, "'");
    return raw;
  }
}

/** Renders `data` and `body` as a frontmatter file; keys keep insertion order, undefined keys are dropped. */
export function serialize(
  data: Record<string, FrontmatterValue | undefined>,
  body: string,
): string {
  const lines = [FENCE];
  for (const [key, val] of Object.entries(data)) {
    if (val === undefined) continue;
    lines.push(val === null ? `${key}:` : `${key}: ${render(val)}`);
  }
  lines.push(FENCE, body.trim(), "");
  return lines.join("\n");
}

function render(val: FrontmatterValue): string {
  if (typeof val !== "string") return JSON.stringify(val);
  // A bare string is kept bare unless YAML or our JSON reading would change it.
  const plain =
    val !== "" &&
    val === val.trim() &&
    !/^[\[{"'!&*#|>%@`-]/.test(val) &&
    !/: |\s#/.test(val) &&
    !/^(true|false|null|~|yes|no|on|off)$/i.test(val) &&
    Number.isNaN(Number(val)) &&
    !val.includes("\n");
  return plain ? val : JSON.stringify(val);
}
