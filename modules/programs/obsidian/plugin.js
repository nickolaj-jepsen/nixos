// Our own commands, built by plugins.nix: format a note's code blocks, and toggle the Claude terminal.
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

module.exports = class Fireproof extends Plugin {
  onload() {
    this.addCommand({
      id: "format-note",
      name: "Format code blocks and lint",
      editorCallback: (editor) => this.format(editor),
    });
    this.addCommand({
      id: "toggle-terminal",
      name: "Open or toggle focus on the Claude terminal",
      callback: () => this.toggleTerminal(),
    });
  }

  // Leaving the terminal is Terminal's own unfocus command (default.nix): it is the only kind of
  // binding that gets through while a terminal has focus.
  toggleTerminal() {
    const { commands, workspace } = this.app;
    const leaves = workspace.getLeavesOfType("terminal:terminal");
    if (!leaves.length) return commands.executeCommandById("terminal:open-terminal.default.root");
    const leaf = leaves.reduce((a, b) => ((b.activeTime ?? 0) > (a.activeTime ?? 0) ? b : a));
    workspace.setActiveLeaf(leaf, { focus: true });
    leaf.view.focus?.();
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
