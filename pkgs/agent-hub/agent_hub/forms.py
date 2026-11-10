"""The answer form's contract, the one every surface shares: find the question round or pick
list a turn ended on, step a draft of answers through it, and write the reply a person would
have typed. Pure and JSON-safe; `formstore` keeps the draft, and each surface only draws `view`.

Parsing is lenient on purpose: the skills' formats are the target, but any agent's numbered
questions should parse well enough to answer. A false positive costs a hint the person ignores.
"""

import hashlib
import json
import re

FENCE = re.compile(r"^\s*(```|~~~)")
RULE = re.compile(r"^\s*(-{3,}|\*{3,}|_{3,})\s*$")
HEADING = re.compile(r"^#{1,6}\s")
# `**Q1. …**`, `### Q2: …`, `1. **…?** …`, `**3.** …`, `Q4) …`; unindented only.
START = re.compile(r"^(?:#{1,6}\s+)?(\*\*)?(Q)?([0-9]{1,3})[.:)](\*\*)?(?:\s+|$)(.*)$")
# `- **A.** …`, `- **A. …**`, `A) …`, `**B.** …`.
OPTION = re.compile(r"^(\s*)(?:[-*+]\s+)?(?:\*\*)?([A-H])[.)](?:\*\*)?\s+(.+)$")
RECOMMENDED = re.compile(r"^\s*(?:>\s*)?\**(?:Recommended|(?:My )?recommendation)\**\s*:\s*\**\s*(.*)$", re.I)
OWN_RECOMMENDATION = re.compile(r"\((?:(?:my )?recommend(?:ed|ation)|my pick)\b[^)]*\)", re.I)
# A letter, then punctuation or the end: "A. The format", "B, because", "**C**"; never "A small".
LEADING_LETTER = re.compile(r"^(?:option\s+)?\**([A-H])\**(?=$|[\s]*[.,:;)]|\s+[—–-]\s)", re.I)
# Several letters leading a recommendation: "A, B and D now", "A through C", "**A** and **C**."
LEADING_LETTERS = re.compile(r"^\**([A-H])\**((?:\s*(?:,\s*and|,|and|&|\+|through|to|–|-)\s*\**[A-H]\**(?![A-Za-z]))+)")
RECOMMEND_IN_TEXT = re.compile(r"\b(?:recommend(?:ed)?:?|lean (?:toward|towards)|(?:I'd|I would) (?:go with|pick))\s+\**(?:option\s+)?([A-H])\b")
ROUTES = (
    (re.compile(r"/grill-me\b|\bgrill(?:ing)? (?:it )?first\b", re.I), "/grill-me"),
    (re.compile(r"/brainstorm\b|\bbrainstorm(?:ing)? (?:it )?first\b", re.I), "/brainstorm"),
    (re.compile(r"(?:·|,)\s*build(?: it)?\b|^\s*build(?: it)?\.?\s*$", re.I), "build"),
)


def _unbold(text):
    return text.replace("**", "").strip()


def _indent(line):
    return len(line) - len(line.lstrip())


def _tidy(lines):
    return re.sub(r"\n{3,}", "\n\n", "\n".join(lines)).strip()


def _split_title(bold_lead, rest):
    """Title and the rest of a start line, whether the bold wraps the label, the title or nothing."""
    if bold_lead:
        end = rest.find("**")
        return (rest, "") if end < 0 else (rest[:end], rest[end + 2:])
    if rest.startswith("**"):
        end = rest.find("**", 2)
        if end > 0:
            return rest[2:end], rest[end + 2:]
    return rest, ""


def _find_starts(lines):
    starts = []
    in_fence = False
    for i, line in enumerate(lines):
        if FENCE.match(line):
            in_fence = not in_fence
        if in_fence:
            continue
        match = START.match(line)
        if not match:
            continue
        bold, q, n, closed, after = match.groups()
        # `**Q1.** …` closed its bold on the label, so a `**` after it is the title's own.
        title, rest = _split_title(bool(bold) and not closed, after)
        if not _unbold(title):
            continue
        starts.append({"line": i, "isQ": bool(q), "n": int(n), "label": f"Q{n}" if q else n,
                       "title": _unbold(title), "rest": rest.strip()})
    return starts


def _last_run(starts):
    """The trailing run of starts: Q-labelled ones when there are any, since numbered lists turn
    up inside their bodies; a run restarts where the numbering goes back."""
    pool = [s for s in starts if s["isQ"]] or starts
    run = []
    for start in pool:
        if run and start["n"] <= run[-1]["n"]:
            run = []
        run.append(start)
    return run


def _block_of(lines, start, following):
    """The lines after a start that belong to it: up to the next start, a rule or a heading."""
    end = following["line"] if following else len(lines)
    block = []
    in_fence = False
    for line in lines[start["line"] + 1:end]:
        if FENCE.match(line):
            in_fence = not in_fence
        if not in_fence and (RULE.match(line) or HEADING.match(line)):
            break
        block.append(line)
    return block


def _leading_letters(recommended, count):
    """The options a recommendation opens on when it names several, a range read as all of it."""
    match = LEADING_LETTERS.match(recommended)
    if not match:
        return []
    letters = [ord(letter) - 65 for letter in re.findall(r"(?<![A-Za-z])[A-H](?![A-Za-z])", match.group(0))]
    if re.search(r"through|\bto\b|–|-", match.group(2)) and len(letters) == 2:
        letters = list(range(letters[0], letters[1] + 1))
    picked = sorted(set(letters))
    return picked if picked and picked[-1] < count else []


def _parse_item(start, block):
    body = [start["rest"]] if start["rest"] else []
    options = []
    recommended = None
    own_pick = None
    i = 0
    while i < len(block):
        line = block[i]
        rec = RECOMMENDED.match(line)
        if rec:
            # A blockquote recommendation goes on over the quote's following lines.
            more = []
            if line.lstrip().startswith(">"):
                while i + 1 < len(block) and block[i + 1].lstrip().startswith(">"):
                    i += 1
                    more.append(block[i].lstrip()[1:].strip())
            recommended = _unbold(" ".join(part for part in [rec.group(1), *more] if part))
            i += 1
            continue
        opt = OPTION.match(line)
        if opt and opt.group(2) == chr(65 + len(options)):
            lead, letter, words = opt.groups()
            detail = []
            while i + 1 < len(block) and block[i + 1].strip() and _indent(block[i + 1]) > len(lead):
                i += 1
                detail.append(block[i].strip())
            # `- **A. Title.** More words`: the bold part is the option, the rest its detail.
            close = words.find("**")
            if close > 0:
                detail.insert(0, words[close + 2:].strip())
            text = _unbold(words[:close] if close > 0 else words)
            if OWN_RECOMMENDATION.search(text):
                own_pick = len(options)
            options.append({"key": letter, "text": text, "detail": _tidy(detail)})
            i += 1
            continue
        body.append(line)
        i += 1
    # A lone "A." is a sentence, not a choice.
    choices = options if len(options) >= 2 else []
    if not choices:
        for option in options:
            body += [f"{option['key']}. {option['text']}", option["detail"]]
    body_text = _tidy(body)
    item = {"label": start["label"], "title": start["title"], "body": body_text, "options": choices}
    if recommended is not None:
        item["recommended"] = recommended
    if choices:
        leading = LEADING_LETTER.match(recommended) if recommended else None
        in_text = None if leading else RECOMMEND_IN_TEXT.search(body_text)
        letter = (leading or in_text).group(1) if (leading or in_text) else None
        index = ord(letter.upper()) - 65 if letter else (own_pick if own_pick is not None else -1)
        several = _leading_letters(recommended or "", len(choices))
        if len(several) > 1:
            item["recommendedOptions"] = several
        elif 0 <= index < len(choices):
            item["recommendedOption"] = index
    return item


def route_of(line):
    return next((route for pattern, route in ROUTES if pattern.search(line)), None)


def _parse_picks(lines, run):
    items = []
    for start in run:
        own = [lines[start["line"]]]
        for line in lines[start["line"] + 1:]:
            if not line.strip() or _indent(line) < 2:
                break
            own.append(line)
        route = route_of(own[-1])
        if not route:
            return None
        # `<title> · <size> · <next>` keeps its fields beside the title.
        title, *fields = " ".join(part for part in (start["title"], start["rest"]) if part).split(" · ")
        detail = [part for part in (" · ".join(fields), *(line.strip() for line in own[1:])) if part]
        options = [{"key": "build", "text": "Build it", "detail": ""}]
        if route != "build":
            options.append({"key": route, "text": f"Route to {route}", "detail": ""})
        items.append({
            "label": start["label"], "title": _unbold(title), "body": "\n".join(detail), "options": options,
            "recommended": "build it" if route == "build" else f"route it to {route}",
            "recommendedOption": 0 if route == "build" else 1,
        })
    return {"kind": "picks", "items": items} if items else None


def parse(text):
    """The round or pick list a message ends on, or None when it asks nothing."""
    lines = re.sub(r"\r\n?", "\n", text).split("\n")
    run = _last_run(_find_starts(lines))
    if not run:
        return None
    if not run[0]["isQ"]:
        picks = _parse_picks(lines, run)
        if picks:
            return picks
    items = [_parse_item(start, _block_of(lines, start, run[i + 1] if i + 1 < len(run) else None))
             for i, start in enumerate(run)]
    asks = text.rstrip().endswith("?") or any(
        "?" in item["title"] or "recommended" in item or item["options"] for item in items)
    return {"kind": "round", "items": items} if asks else None


def form_id(form):
    """Names a form by what it asks: a turn that asks the same round again keeps its answers, and
    a step or a delivery aimed at an older form lands on nothing."""
    return hashlib.sha256(json.dumps(form, sort_keys=True).encode()).hexdigest()[:16]


def new_draft(form):
    count = len(form["items"])
    return {"answers": [None] * count, "notes": [""] * count, "note": "", "step": 0}


def is_review(form, draft):
    return draft["step"] >= len(form["items"])


def go(form, draft, step):
    return {**draft, "step": max(0, min(len(form["items"]), step))}


def _can_accept(item):
    return "recommended" in item or "recommendedOption" in item or "recommendedOptions" in item


def _accepted(item):
    """The answer that takes an item's recommendation: its options when it names any, else a yes."""
    if "recommendedOptions" in item:
        return {"kind": "options", "indices": item["recommendedOptions"]}
    if "recommendedOption" in item:
        return {"kind": "option", "index": item["recommendedOption"]}
    return {"kind": "accept"}


def entries(item):
    """What the form offers for one item: its options, or with none a yes to its recommendation,
    and a write-in. Beside options a recommendation is only said, never an entry of its own."""
    rows = [{"kind": "option", "index": index} for index in range(len(item["options"]))]
    if "recommended" in item and not rows:
        rows.append({"kind": "accept"})
    rows.append({"kind": "write"})
    return rows


def _is_chosen(item, answer, entry):
    if not answer:
        return False
    if entry["kind"] == "write":
        return answer["kind"] == "text"
    if entry["kind"] == "accept":
        return answer["kind"] == "accept"
    if answer["kind"] == "option":
        return answer["index"] == entry["index"]
    if answer["kind"] == "options":
        return entry["index"] in answer["indices"]
    return answer["kind"] == "accept" and item.get("recommendedOption") == entry["index"]


def _start_entry(item, answer):
    """The entry the cursor starts on: the item's answer, else its recommendation, else the first."""
    rows = entries(item)
    chosen = next((i for i, entry in enumerate(rows) if _is_chosen(item, answer, entry)), None)
    if chosen is not None:
        return chosen
    return next((i for i, entry in enumerate(rows) if _is_chosen(item, {"kind": "accept"}, entry)), 0)


def _clear(form, draft):
    if is_review(form, draft):
        return draft
    answers = list(draft["answers"])
    answers[draft["step"]] = None
    return {**draft, "answers": answers}


def _record(form, draft, value):
    """Records the shown item's answer and stays on it, so a note can follow."""
    if is_review(form, draft):
        return draft
    item = form["items"][draft["step"]]
    if value["kind"] == "accept" and not _can_accept(item):
        return draft
    if value["kind"] == "option" and not 0 <= value["index"] < len(item["options"]):
        return draft
    if value["kind"] == "options" and not value["indices"]:
        return _clear(form, draft)
    if value["kind"] == "text":
        if not value["text"].strip():
            return _clear(form, draft)
        value = {"kind": "text", "text": value["text"].strip()}
    answers = list(draft["answers"])
    answers[draft["step"]] = value
    return {**draft, "answers": answers}


def _can_take_several(form, item):
    return form["kind"] == "round" and len(item["options"]) >= 2


def _toggle(form, draft, index):
    """Adds an option to the shown item's answer, or takes it out; a single pick starts the set."""
    if is_review(form, draft):
        return draft
    item = form["items"][draft["step"]]
    if not _can_take_several(form, item) or not 0 <= index < len(item["options"]):
        return draft
    answer = draft["answers"][draft["step"]]
    held = set(answer["indices"] if answer and answer["kind"] == "options"
               else [answer["index"]] if answer and answer["kind"] == "option" else [])
    return _record(form, draft, {"kind": "options", "indices": sorted(held ^ {index})})


def _onward(form, draft):
    """After an answer: the next item still unanswered, looking on and then from the top, or
    the review when every item has one."""
    count = len(form["items"])
    order = [*range(draft["step"] + 1, count), *range(draft["step"])]
    return go(form, draft, next((i for i in order if not draft["answers"][i]), count))


def _set_note(form, draft, text):
    """The shown item's note, or on the review the whole round's."""
    note = text.strip()
    if is_review(form, draft):
        return {**draft, "note": note}
    notes = list(draft["notes"])
    notes[draft["step"]] = note
    return {**draft, "notes": notes}


def apply(form, draft, action):
    """The draft after one thing a person did at any surface; what can't apply changes nothing.

    `action["do"]` is `pick` (`entry`, an index into the shown item's entries; a write-in has
    nothing to record until `write`),
    `toggle` (`entry`, one of several options), `write` (`text`, then on likewise), `note`
    (`text`), `accept` (the item's recommendation, whatever it names), `next` (on to the next
    item unanswered), `go` (`step`), `back`, `forward`, `skip` or `review`. Raises ValueError for another word."""
    step = draft["step"]
    what = action.get("do")
    if what in ("pick", "toggle"):
        if is_review(form, draft):
            return draft
        rows = entries(form["items"][step])
        index = action.get("entry", -1)
        if not 0 <= index < len(rows) or rows[index]["kind"] == "write":
            return draft
        if what == "toggle":
            return _toggle(form, draft, index) if rows[index]["kind"] == "option" else draft
        return _record(form, draft, rows[index])
    if what == "write":
        written = _record(form, draft, {"kind": "text", "text": action.get("text") or ""})
        return _onward(form, written) if written["answers"][step] else written
    if what == "note":
        return _set_note(form, draft, action.get("text") or "")
    if what == "accept":
        if is_review(form, draft) or not _can_accept(form["items"][step]):
            return draft
        return _record(form, draft, _accepted(form["items"][step]))
    if what == "next":
        return draft if is_review(form, draft) else _onward(form, draft)
    if what == "go":
        return go(form, draft, action.get("step", step))
    if what == "back":
        return go(form, draft, step - 1)
    if what == "forward":
        return go(form, draft, step + 1)
    if what == "skip":
        return go(form, _clear(form, draft), step + 1)
    if what == "review":
        return go(form, draft, len(form["items"]))
    raise ValueError(f"no such action: {what!r}")


def _is_recommended(item, answer):
    if not answer:
        return False
    if answer["kind"] == "options":
        return answer["indices"] == item.get("recommendedOptions", [item.get("recommendedOption")])
    return answer["kind"] == "accept" or (answer["kind"] == "option" and answer["index"] == item.get("recommendedOption"))


def _said(item, answer):
    """What the reply says for one answer: "yes", a letter or several, a route, or the text."""
    if answer["kind"] == "text":
        return answer["text"]
    if answer["kind"] == "options":
        return ", ".join(item["options"][index]["key"] for index in answer["indices"])
    index = answer["index"] if answer["kind"] == "option" else item.get("recommendedOption")
    return item["options"][index]["key"] if index is not None else "yes"


NO_ANSWER = "no answer yet"


def _noted(line, note):
    """A reply line and, under it, the note it carries."""
    return [line, f"    Note: {note}"] if note else [line]


def _round_reply(form, draft):
    every = all(_is_recommended(item, answer) and not note
                for item, answer, note in zip(form["items"], draft["answers"], draft["notes"]))
    if every and not draft["note"]:
        return ["yes"]
    lines = []
    for item, answer, note in zip(form["items"], draft["answers"], draft["notes"]):
        if answer:
            what = "yes" if answer["kind"] == "accept" else _said(item, answer)
            lines += _noted(f"{item['label']}: {what}", note)
        elif note:
            lines += _noted(f"{item['label']}: {NO_ANSWER}", note)
    return lines


def _picks_reply(form, draft):
    builds, rest = [], []
    for item, answer, note in zip(form["items"], draft["answers"], draft["notes"]):
        label = item["label"]
        if not answer:
            if note:
                rest += _noted(f"{label}: {NO_ANSWER}", note)
            continue
        what = _said(item, answer)
        if what == "build" and not note:
            builds.append(label)
        elif what == "build":
            rest += _noted(f"do {label}", note)
        elif answer["kind"] == "text":
            rest += _noted(f"{label}: {answer['text']}", note)
        else:
            rest += _noted(f"{label} → {what}", note)
    return ([f"do {', '.join(builds)}"] if builds else []) + rest


def reply(form, draft):
    """The reply as the person would type it; "" when nothing was answered."""
    lines = _round_reply(form, draft) if form["kind"] == "round" else _picks_reply(form, draft)
    if draft["note"]:
        lines.append(f"Overall: {draft['note']}")
    return "\n".join(lines)


def _entry_text(form, item, entry):
    if entry["kind"] == "write":
        return "Write your own answer" if form["kind"] == "round" else "Something else"
    if entry["kind"] == "accept":
        return f"Yes: {item.get('recommended') or 'as recommended'}"
    option = item["options"][entry["index"]]
    return f"{option['key']}. {option['text']}" if form["kind"] == "round" else option["text"]


def _shown(item, answer):
    """What an answer reads as on the review: the option's words, not just its key."""
    if not answer:
        return "skipped"
    if answer["kind"] == "text":
        return f'"{answer["text"]}"'
    if answer["kind"] == "options":
        return f"{_said(item, answer)}: {'; '.join(item['options'][index]['text'] for index in answer['indices'])}"
    index = answer["index"] if answer["kind"] == "option" else item.get("recommendedOption")
    return "yes" if index is None else f"{_said(item, answer)}: {item['options'][index]['text']}"


def title(form):
    count = len(form["items"])
    if form["kind"] == "round":
        return f"Answer {count} question{'' if count == 1 else 's'}"
    return f"Pick from {count} item{'' if count == 1 else 's'}"


def _item_view(form, draft):
    if is_review(form, draft):
        return None
    item = form["items"][draft["step"]]
    answer = draft["answers"][draft["step"]]
    recommended = item.get("recommendedOptions", [item.get("recommendedOption")])
    return {
        "label": item["label"],
        "title": item["title"],
        "body": item["body"],
        "entries": [{
            "kind": entry["kind"],
            "text": _entry_text(form, item, entry),
            "detail": item["options"][entry["index"]]["detail"] if entry["kind"] == "option" else "",
            "isRecommended": entry["kind"] == "option" and entry["index"] in recommended,
            "isChosen": _is_chosen(item, answer, entry),
        } for entry in entries(item)],
        "start": _start_entry(item, answer),
        # What it recommends among its options and why; with no options that is the accept entry.
        "recommended": item.get("recommended", "") if item["options"] else "",
        "canSeveral": _can_take_several(form, item),
        # Its answer is several, or with none yet its recommendation is.
        "isSeveral": answer["kind"] == "options" if answer else "recommendedOptions" in item,
        "canAccept": _can_accept(item),
        "note": draft["notes"][draft["step"]],
        "written": answer["text"] if answer and answer["kind"] == "text" else "",
    }


def view(form, draft):
    """All a surface needs to draw the draft, with no form logic of its own (`FORM_VIEW` in
    `protocol`)."""
    return {
        "id": form_id(form),
        "kind": form["kind"],
        "title": title(form),
        "count": len(form["items"]),
        "answered": sum(1 for answer in draft["answers"] if answer),
        "step": draft["step"],
        "isReview": is_review(form, draft),
        "item": _item_view(form, draft),
        "review": [{"label": item["label"], "shown": _shown(item, answer), "isAnswered": bool(answer), "note": note}
                   for item, answer, note in zip(form["items"], draft["answers"], draft["notes"])],
        "note": draft["note"],
        "reply": reply(form, draft),
        "pending": False,
    }
