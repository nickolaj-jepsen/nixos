"""Each session's open answer form and its draft, one file per session beside the hub's state.

The files are the truth, not the daemon: `agent-hub answer` and the daemon both go through this
module, so a form keeps working with the hub down and every surface shares one draft. A surface
sees a change by the file's mtime, and the daemon by `form-changed`.
"""

import fcntl
import json
import os
import re
from contextlib import contextmanager
from pathlib import Path

from . import forms
from .common import now_ms, write_atomic

MAX_AGE_MS = 7 * 24 * 3600 * 1000
# A delivery nobody took by then is dropped: a session resumed tomorrow must not send today's reply.
DELIVERY_TTL_MS = 30_000
# Remote rows' `host:id` stay out: a form is answered on the host its session runs on.
SESSION_ID = re.compile(r"[A-Za-z0-9_-][A-Za-z0-9._-]{0,127}")


def root_of(cfg):
    return Path(cfg["state"]).expanduser().parent / "forms"


def path_of(root, session):
    """The session's file; ValueError for an id that couldn't name one here."""
    if not isinstance(session, str) or not SESSION_ID.fullmatch(session):
        raise ValueError(f"no form can belong to session {session!r}")
    return root / f"{session}.json"


@contextmanager
def _locked(root):
    """One writer at a time: the CLI and the daemon both read, change and write a whole file."""
    root.mkdir(parents=True, exist_ok=True)
    with open(root / ".lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


def load(root, session):
    """The session's record, or None. A rename replaces it whole, so a read needs no lock."""
    path = path_of(root, session)
    try:
        record = json.loads(path.read_text())
    except (OSError, ValueError):
        return None
    return record if isinstance(record, dict) and record.get("form") else None


def _save(root, session, record):
    write_atomic(path_of(root, session), json.dumps(record))


def _delivery(record, now):
    delivery = record.get("delivery")
    return delivery if delivery and now - delivery["at"] <= DELIVERY_TTL_MS else None


def _view(record, now):
    return {**forms.view(record["form"], record["draft"]), "pending": _delivery(record, now) is not None}


def view_of(root, session):
    """What the session's form looks like now, or None when it has none."""
    if not SESSION_ID.fullmatch(session):
        return None
    record = load(root, session)
    return _view(record, now_ms()) if record else None


def offer(root, session, text):
    """A turn ended on `text`. A new round replaces the form and the same one keeps its answers;
    a turn that asks nothing leaves it, since a turn a background task woke ends on that task's
    news while the round still waits. Returns the view, or None with no form."""
    form = forms.parse(text)
    with _locked(root):
        record = load(root, session)
        if form and (record is None or forms.form_id(record["form"]) != forms.form_id(form)):
            record = {"form": form, "draft": forms.new_draft(form), "at": now_ms()}
            _save(root, session, record)
    return _view(record, now_ms()) if record else None


def step(root, session, action, form=None):
    """Applies one action to the draft, when `form` is still the form showing. Returns the view."""
    with _locked(root):
        record = load(root, session)
        if record is None:
            return None
        if form is None or form == forms.form_id(record["form"]):
            record = {**record, "draft": forms.apply(record["form"], record["draft"], action)}
            _save(root, session, record)
    return _view(record, now_ms())


def deliver(root, session, submit, form=None):
    """Leaves the reply for the session's own TUI to take: into its prompt, or with `submit` as
    what you send. Returns the view, or None when there is no such form or nothing is answered."""
    with _locked(root):
        record = load(root, session)
        if record is None or (form is not None and form != forms.form_id(record["form"])):
            return None
        text = forms.reply(record["form"], record["draft"])
        if not text:
            return None
        now = now_ms()
        record = {**record, "delivery": {"text": text, "submit": bool(submit), "at": now}}
        _save(root, session, record)
    return _view(record, now)


def sync(root, session):
    """What a TUI asks when the file moved: `{view, delivery}`, handing over a delivery at most
    once. A reply it takes to send is as good as sent, so that drops the form."""
    path = path_of(root, session)
    now = now_ms()
    with _locked(root):
        record = load(root, session)
        if record is None:
            return {"view": None, "delivery": None}
        delivery = _delivery(record, now)
        if "delivery" in record:
            record = {key: value for key, value in record.items() if key != "delivery"}
            if delivery and delivery["submit"]:
                path.unlink(missing_ok=True)
                return {"view": None, "delivery": delivery}
            _save(root, session, record)
    return {"view": _view(record, now), "delivery": delivery}


def drop(root, session):
    """The person spoke: their own message answers the round, or moves past it."""
    with _locked(root):
        path_of(root, session).unlink(missing_ok=True)


def listing(root):
    """Every open form as `(session, view)`, newest first."""
    try:
        paths = sorted(root.glob("*.json"), key=lambda path: path.stat().st_mtime, reverse=True)
    except OSError:
        return []
    found = ((path.stem, view_of(root, path.stem)) for path in paths)
    return [(session, view) for session, view in found if view]


def prune(root, now):
    """Forgets forms nobody has touched in a week, as a session that never came back leaves them."""
    try:
        paths = list(root.glob("*.json"))
    except OSError:
        return
    for path in paths:
        try:
            if now - path.stat().st_mtime * 1000 > MAX_AGE_MS:
                os.unlink(path)
        except OSError:
            pass
