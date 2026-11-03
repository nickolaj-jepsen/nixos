"""A note's Markdown as the rich text the reader draws.

Qt's rich text and its Markdown mode both fetch an image a document names, so opening a note
could reach out to anywhere. Here images become their alt text and raw HTML stays literal, and a
link lives only if it goes to https or to another note. Colours and fonts are the reader's: it
styles these elements from the bar's theme.
"""

import html
import posixpath
import re
from urllib.parse import unquote

from markdown_it import MarkdownIt

NOTES_DIR = "/.local/share/agents/"
# The whole of an inline code span that names a note, as an agent writes one in prose.
NOTE_IN_CODE = re.compile(r"(~|/[^`]*?)/\.local/share/agents/[^`\n]+\.md")


def _note_link(href, path):
    """`note:<path>` for a relative link to Markdown beside this note, or None."""
    if re.match(r"^[a-z][a-z0-9+.-]*:", href, re.I) or href.startswith("#"):
        return None
    target = unquote(href.split("#", 1)[0])
    if not target.endswith(".md"):
        return None
    return "note:" + posixpath.normpath(posixpath.join(posixpath.dirname(path), target))


def _code_target(code, path):
    """`note:<path>` when an inline code span is nothing but a note's path, or None."""
    if not NOTE_IN_CODE.fullmatch(code):
        return None
    if not code.startswith("~"):
        return "note:" + code
    # `~` is the home of the host the note is on, which this one may not share.
    at = path.find(NOTES_DIR)
    return "note:" + path[:at] + code[1:] if at > 0 else None


def render(text, path):
    """The HTML of a note's Markdown; `path` is where it lies, for its relative links."""
    md = MarkdownIt("commonmark", {"html": False}).enable(["table", "strikethrough"])
    live = []

    def link_open(_self, tokens, idx, _options, _env):
        href = tokens[idx].attrGet("href") or ""
        target = href if href.startswith("https://") else _note_link(href, path)
        live.append(target is not None)
        return f'<a href="{html.escape(target, quote=True)}">' if target else ""

    def link_close(_self, _tokens, _idx, _options, _env):
        return "</a>" if live.pop() else ""

    def image(_self, tokens, idx, _options, _env):
        return html.escape(tokens[idx].content or "image")

    def code_inline(_self, tokens, idx, _options, _env):
        code = tokens[idx].content
        target = _code_target(code, path)
        shown = f"<code>{html.escape(code)}</code>"
        return f'<a href="{html.escape(target, quote=True)}">{shown}</a>' if target else shown

    def fence(_self, tokens, idx, _options, _env):
        # A table is the one block Qt's rich text pads and fills behind.
        return (f'<table class="fence" width="100%" cellpadding="8"><tr><td><pre>{html.escape(tokens[idx].content.rstrip())}'
                "</pre></td></tr></table><p></p>")

    def table_open(_self, _tokens, _idx, _options, _env):
        return '<table class="data" border="1" cellspacing="0" cellpadding="5" width="100%">'

    rules = {"link_open": link_open, "link_close": link_close, "image": image, "code_inline": code_inline,
             "fence": fence, "code_block": fence, "table_open": table_open}
    for name, rule in rules.items():
        md.add_render_rule(name, rule)
    return md.render(text)
