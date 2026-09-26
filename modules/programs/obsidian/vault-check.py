"""Checks the notes vault against the conventions in its AGENTS.md.

Usage: obsidian-vault-check [--orphans] [vault]. Prints one problem per line as
`path: problem` and exits 1 if there are any. Read-only.
"""
import os
import re
import sys

import yaml

# Mirrors the Linter's yaml-key-sort priority list in plugins.nix.
KEY_ORDER = ["created", "area", "tags", "kind", "status", "date", "event", "attendees",
             "project", "started", "ended", "source", "servings", "summary"]
KNOWN_KEYS = set(KEY_ORDER) | {"aliases", "cssclasses"}
AREAS = {"personal", "work"}
# Folder -> (required keys, {key: allowed values})
SCHEMA = {
    "Meetings": (["date", "attendees", "project"], {}),
    "Projects": (["status", "started", "ended"], {"status": {"idea", "active", "paused", "done"}}),
    "Recipes": (["source", "servings"], {}),
    "Writing": (["kind", "status"], {"kind": {"blog", "ctf"}, "status": {"draft", "published"}}),
}
SKIP_DIRS = {"Templates", "Attachments", "Bases"}
ROOT_FILES = {"AGENTS.md"}
DATE = re.compile(r"\d{4}-\d{2}-\d{2}$")
FENCE = re.compile(r"^(`{3,}|~{3,}).*?^\1[`~]*[ \t]*$", re.M | re.S)
INLINE_CODE = re.compile(r"`[^`\n]*`")
WIKILINK = re.compile(r"!?\[\[([^\]|#^]*)[^\]]*\]\]")
MDLINK = re.compile(r"!?\[[^\]]*\]\((?:<([^>]*)>|([^)\s]+))[^)]*\)")


def walk(vault):
    for root, dirs, files in os.walk(vault):
        rel = os.path.relpath(root, vault)
        dirs[:] = [d for d in dirs if not d.startswith(".")]
        for f in files:
            if not f.startswith("."):
                yield os.path.normpath(os.path.join(rel, f))


def split_frontmatter(text):
    m = re.match(r"---\n(.*?)\n?---\n", text, re.S)
    if not m:
        return None, text
    # BaseLoader keeps scalars as written, so dates stay strings to check.
    return yaml.load(m.group(1), Loader=yaml.BaseLoader) or {}, text[m.end():]


def check_frontmatter(path, fm, problems):
    top = path.split(os.sep)[0]
    for key in ("created", "area"):
        if key not in fm:
            problems.append(f"{path}: missing `{key}`")
    if fm.get("created") and not DATE.match(fm["created"]):
        problems.append(f"{path}: `created` is not YYYY-MM-DD: {fm['created']!r}")
    if fm.get("area") and fm["area"] not in AREAS:
        problems.append(f"{path}: `area` must be one of {sorted(AREAS)}: {fm['area']!r}")
    for key in fm:
        if key not in KNOWN_KEYS:
            problems.append(f"{path}: unknown key `{key}`")

    required, allowed = SCHEMA.get(top, ([], {}))
    # Notes under Projects/<project>/ are sub-notes of that project, not projects.
    if top == "Projects" and path.count(os.sep) > 1:
        required, allowed = [], {}
    for key in required:
        if key not in fm:
            problems.append(f"{path}: missing `{key}` ({top})")
    for key, values in allowed.items():
        if fm.get(key) and fm[key] not in values:
            problems.append(f"{path}: `{key}` must be one of {sorted(values)}: {fm[key]!r}")
    for key in ("date", "started", "ended"):
        if fm.get(key) and not DATE.match(fm[key]):
            problems.append(f"{path}: `{key}` is not YYYY-MM-DD: {fm[key]!r}")
    if top == "Meetings" and not re.match(r"\d{4}-\d{2}-\d{2} ", os.path.basename(path)):
        problems.append(f"{path}: meeting file name should be `YYYY-MM-DD Topic.md`")
    if top == "Writing" and fm.get("kind") == "ctf" and fm.get("event") != os.path.basename(os.path.dirname(path)):
        problems.append(f"{path}: CTF `event` should be its folder name")
    if "summary" in fm and (not isinstance(fm["summary"], str) or "\n" in fm["summary"].strip()):
        problems.append(f"{path}: `summary` should be a single line")

    ranked = [k for k in fm if k in KEY_ORDER]
    if ranked != sorted(ranked, key=KEY_ORDER.index) or any(
            k not in KEY_ORDER for k in list(fm)[:len(ranked)]):
        problems.append(f"{path}: frontmatter keys out of Linter order ({', '.join(fm)})")


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    vault = os.path.expanduser(args[0] if args else "~/obsidian/notes")
    files = sorted(walk(vault))
    notes = [f for f in files if f.endswith(".md")]
    names = {}
    for f in files:
        names.setdefault(os.path.basename(f).lower(), f)
        if f.endswith(".md"):
            names.setdefault(os.path.basename(f)[:-3].lower(), f)
    paths = {f.lower(): f for f in files} | {f[:-3].lower(): f for f in notes}

    problems, linked = [], set()
    for path in notes:
        text = open(os.path.join(vault, path), encoding="utf-8").read()
        top = path.split(os.sep)[0]
        in_scope = top not in SKIP_DIRS and path not in ROOT_FILES
        try:
            fm, body = split_frontmatter(text)
        except yaml.YAMLError as err:
            problems.append(f"{path}: invalid frontmatter: {str(err).splitlines()[0]}")
            continue
        if in_scope:
            if fm is None:
                problems.append(f"{path}: no frontmatter")
            elif isinstance(fm, dict):
                check_frontmatter(path, fm, problems)
            if "<%" in text:
                problems.append(f"{path}: unresolved Templater syntax `<%`")

        prose = INLINE_CODE.sub("", FENCE.sub("", body))
        for target in WIKILINK.findall(prose) + ["".join(m) for m in MDLINK.findall(prose)]:
            target = target.split("#")[0].strip().replace("%20", " ")
            if not target or re.match(r"\w+:", target):
                continue
            key = target.lower().lstrip("/")
            hit = paths.get(key) or names.get(key) or names.get(os.path.basename(key))
            if hit:
                linked.add(hit.lower())
            elif top != "Templates":
                problems.append(f"{path}: broken link [[{target}]]")

    if "--orphans" in sys.argv:
        for path in notes:
            top = path.split(os.sep)[0]
            if top not in SKIP_DIRS | {"Inbox"} and path not in ROOT_FILES and path.lower() not in linked:
                print(f"{path}: orphan (no incoming links)")

    for p in problems:
        print(p)
    sys.exit(1 if problems else 0)


main()
