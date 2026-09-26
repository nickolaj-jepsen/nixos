// Formats a note's fenced code blocks with Nix-pinned formatters, then runs the Linter. Built by plugins.nix.
const { Notice, Plugin } = require("obsidian");
const { execFile } = require("child_process");
const { tmpdir } = require("os");

// fence language -> [command, ...args], filled in by plugins.nix; reads the block on stdin.
const FORMATTERS = @formatters@;

// indent, fence, language, body, then a closing fence of the same kind and at least the same length.
const FENCE = /^([ \t]*)(`{3,}|~{3,})[ \t]*([^\s`]*)[^\n]*\n([\s\S]*?)^[ \t]*\2[`~]*[ \t]*$/gm;

function run([cmd, ...args], input) {
  return new Promise((resolve, reject) => {
    // A neutral cwd so formatters never pick up a stray project config.
    const child = execFile(cmd, args, { cwd: tmpdir(), timeout: 10000, maxBuffer: 16 << 20 }, (err, stdout, stderr) =>
      err ? reject(new Error((stderr || err.message).trim().split("\n")[0])) : resolve(stdout),
    );
    child.stdin.end(input);
  });
}

// Blocks nested in lists carry the list's indent, which the formatters must not see.
const dedent = (body, indent) => body.replace(new RegExp(`^${indent}`, "gm"), "");
const reindent = (body, indent) => body.replace(/^(?=.)/gm, indent);

module.exports = class FireproofFormat extends Plugin {
  onload() {
    this.addCommand({
      id: "format-note",
      name: "Format code blocks and lint",
      editorCallback: (editor) => this.format(editor),
    });
  }

  async format(editor) {
    const text = editor.getValue();
    const blocks = [...text.matchAll(FENCE)].filter((m) => FORMATTERS[m[3].toLowerCase()]);
    const failed = [];
    const changes = [];
    await Promise.all(
      blocks.map(async (m) => {
        const [, indent, , lang, body] = m;
        try {
          const out = reindent(await run(FORMATTERS[lang.toLowerCase()], dedent(body, indent)), indent);
          if (out.trimEnd() === body.trimEnd()) return;
          const from = m.index + m[0].indexOf("\n") + 1;
          changes.push({ from, to: from + body.length, text: out.endsWith("\n") ? out : `${out}\n` });
        } catch (err) {
          failed.push(`${lang}: ${err.message}`);
        }
      }),
    );
    // Offsets all refer to the original text; one sorted change set is a single undo step.
    if (changes.length)
      editor.transaction({
        changes: changes
          .sort((a, b) => a.from - b.from)
          .map(({ from, to, text }) => ({ from: editor.offsetToPos(from), to: editor.offsetToPos(to), text })),
      });
    if (failed.length) new Notice(`Left ${failed.length} block(s) unformatted:\n${failed.join("\n")}`, 10000);
    this.app.commands.executeCommandById("obsidian-linter:lint-file");
  }
};
