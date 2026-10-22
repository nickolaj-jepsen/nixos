"""Print quota windows (and credit allowance spend) for AI agent subscriptions.

Output is a table, or JSON with --json.

Providers come from $XDG_CONFIG_HOME/ai-usage/config.json (written by the
ai-usage home-manager leaf). Each provider's last result is cached per id for
CACHE_TTL; a failed fetch serves the cached result marked stale. Credentials
are only ever read, never refreshed or written.
"""

import argparse
import calendar
import hashlib
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.parse import urlencode

CACHE_TTL = timedelta(minutes=2)
# Bump when the cached entry shape changes, so an upgrade discards old entries.
CACHE_VERSION = 2
TIMEOUT = 10
# Projections from the first few % of a window, or from trivial usage, are noise.
MIN_ELAPSED_PCT = 5
MIN_USED_PCT = 10
CURRENCY_SYMBOLS = {"EUR": "€", "USD": "$", "GBP": "£"}


class FetchError(Exception):
    pass


def now():
    return datetime.now(timezone.utc)


def parse_time(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def month_before(t):
    year, month = (t.year, t.month - 1) if t.month > 1 else (t.year - 1, 12)
    # Clamp to the shorter month (e.g. 31 Mar -> 28/29 Feb).
    return t.replace(year=year, month=month, day=min(t.day, calendar.monthrange(year, month)[1]))


def credit_arrival(day, year, month):
    return datetime(year, month, min(day, calendar.monthrange(year, month)[1]), tzinfo=timezone.utc)


def credit_cycle(day, t):
    """The cycle containing `t`: credits arrive each month at `day`, clamped to its last."""
    year, month = t.year, t.month
    if credit_arrival(day, year, month) <= t:
        year, month = (year + 1, 1) if month == 12 else (year, month + 1)
    resets = credit_arrival(day, year, month)
    prev_year, prev_month = (year - 1, 12) if month == 1 else (year, month - 1)
    return credit_arrival(day, prev_year, prev_month), resets


def money(amount, currency):
    text = f"{amount:.2f}".removesuffix(".00")
    symbol = CURRENCY_SYMBOLS.get(currency)
    return f"{symbol}{text}" if symbol else f"{text} {currency}".rstrip()


def keeps(p, key):
    """A provider's `windows` list, when present, is the allowlist of raw window keys."""
    wanted = p.get("windows")
    return not wanted or key in wanted


def window(label, used_pct, resets_at, length, ring=None, detail=None, starts=None):
    """A quota window; `length` is a timedelta, or "month" for a calendar month."""
    resets = parse_time(resets_at) if isinstance(resets_at, str) else resets_at
    if starts is None:
        starts = month_before(resets) if length == "month" else resets - length
    return {
        "label": label,
        "usedPct": round(float(used_pct), 1),
        "startsAt": starts.isoformat(),
        "resetsAt": resets.isoformat(),
        "ring": ring,
        "detail": detail,
    }


def http_json(url, headers):
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as e:
        raise FetchError(f"HTTP {e.code}") from e
    except (urllib.error.URLError, TimeoutError) as e:
        raise FetchError(f"network: {getattr(e, 'reason', e)}") from e
    except json.JSONDecodeError as e:
        raise FetchError("response is not JSON") from e


def claude_credentials(config_dir):
    if sys.platform == "darwin":
        default = Path.home() / ".claude"
        service = "Claude Code-credentials"
        # Claude Code suffixes the Keychain item for a non-default CLAUDE_CONFIG_DIR.
        if Path(config_dir) != default:
            service += "-" + hashlib.sha256(config_dir.encode()).hexdigest()[:8]
        found = subprocess.run(
            ["security", "find-generic-password", "-s", service, "-w"],
            capture_output=True,
            text=True,
        )
        if found.returncode == 0:
            return json.loads(found.stdout)
    path = Path(config_dir) / ".credentials.json"
    try:
        return json.loads(path.read_text())
    except FileNotFoundError as e:
        raise FetchError("not logged in") from e


def fetch_claude(p):
    oauth = claude_credentials(p["configDir"]).get("claudeAiOauth") or {}
    token = oauth.get("accessToken")
    if not token:
        raise FetchError("not logged in")
    # Refreshing would rotate Claude Code's refresh token; wait for it to refresh instead.
    if oauth.get("expiresAt", 0) / 1000 < now().timestamp():
        raise FetchError("token expired; run claude to refresh it")
    data = http_json(
        "https://api.anthropic.com/api/oauth/usage",
        {
            "Authorization": f"Bearer {token}",
            "anthropic-beta": "oauth-2025-04-20",
            "User-Agent": f"claude-code/{p.get('clientVersion', '2.1.0')}",
        },
    )
    windows = []
    for key, label, length, ring in [
        ("five_hour", "5h", timedelta(hours=5), "outer"),
        ("seven_day", "7d", timedelta(days=7), "inner"),
        ("seven_day_opus", "7d Opus", timedelta(days=7), None),
        ("seven_day_sonnet", "7d Sonnet", timedelta(days=7), None),
    ]:
        if not keeps(p, key):
            continue
        w = data.get(key)
        if w and w.get("utilization") is not None and w.get("resets_at"):
            windows.append(window(label, w["utilization"], w["resets_at"], length, ring))
    overage = None
    extra = data.get("extra_usage") or {}
    if extra.get("is_enabled"):
        # Amounts are in minor currency units.
        used = (extra.get("used_credits") or 0) / 100
        limit = (extra.get("monthly_limit") or 0) / 100
        currency = extra.get("currency") or ""
        overage = {
            "active": used > 0,
            "text": f"{money(used, currency)} of {money(limit, currency)} extra this month",
        }
    return {"windows": windows, "overage": overage}


def fetch_opencode_go(p):
    token = Path(p["keyFile"]).read_text().strip()
    data = http_json(
        "https://opencode.ai/zen/go/v1/usage",
        {"Authorization": f"Bearer {token}", "User-Agent": "ai-usage"},
    )
    usage = data.get("usage") or {}
    windows = []
    for key, label, length, ring in [
        ("rolling", "5h", timedelta(hours=5), "outer"),
        ("weekly", "7d", timedelta(days=7), "inner"),
        ("monthly", "month", "month", None),
    ]:
        if not keeps(p, key):
            continue
        w = usage.get(key)
        if w and w.get("percent") is not None and w.get("resetsAt"):
            windows.append(window(label, w["percent"], w["resetsAt"], length, ring))
    return {"windows": windows, "overage": None}


def anthropic_spend(token, starts, ends):
    """Organization spend in USD over [starts, ends), following pagination."""
    # Amounts are decimal strings in dollars (the reference response carries five
    # decimals), despite the guide calling them cents.
    headers = {"x-api-key": token, "anthropic-version": "2023-06-01", "User-Agent": "ai-usage"}
    total, page = 0.0, None
    while True:
        query = {
            "starting_at": starts.isoformat(),
            "ending_at": ends.isoformat(),
            "bucket_width": "1d",
            "limit": 31,
        }
        if page:
            query["page"] = page
        data = http_json(
            "https://api.anthropic.com/v1/organizations/cost_report?" + urlencode(query), headers
        )
        for bucket in data.get("data") or []:
            for result in bucket.get("results") or []:
                total += float(result.get("amount") or 0)
        page = data.get("next_page")
        if not data.get("has_more") or not page:
            return total


def fetch_anthropic_credits(p):
    """Spend against the platform credit allowance that arrives each Max cycle.

    Lasts until a balance endpoint exists; the credits expire at the end of the
    cycle, so `allowance - spend` is what is left to burn.
    """
    token = Path(p["keyFile"]).read_text().strip()
    allowance = float(p["allowance"])
    currency = p.get("currency", "USD")
    t = now()
    starts, resets = credit_cycle(int(p["creditDay"]), t)
    try:
        spent = anthropic_spend(token, starts, t)
    except FetchError as e:
        if str(e) in ("HTTP 401", "HTTP 403"):
            raise FetchError(f"cost report rejected the key ({e}); it needs org-level access") from e
        raise
    used = spent / allowance * 100 if allowance else 0
    detail = f"{money(spent, currency)} of {money(allowance, currency)} spent"
    return {
        "windows": [window("credit", used, resets, "month", "outer", detail, starts)],
        "overage": None,
        "credit": {
            "remaining": round(max(0.0, allowance - spent), 2),
            "allowance": allowance,
            "currency": currency,
        },
    }


def fetch_copilot(p):
    token = subprocess.run(
        [p.get("gh", "gh"), "auth", "token"], capture_output=True, text=True
    ).stdout.strip()
    if not token:
        raise FetchError("gh not logged in")
    data = http_json(
        "https://api.github.com/copilot_internal/user",
        {
            "Authorization": f"token {token}",
            "Accept": "application/json",
            # copilot_internal answers only editor clients.
            "Editor-Version": "vscode/1.105.0",
            "User-Agent": "GitHubCopilotChat/0.32.0",
        },
    )
    premium = (data.get("quota_snapshots") or {}).get("premium_interactions") or {}
    reset = data.get("quota_reset_date_utc") or data.get("quota_reset_date")
    windows, overage = [], None
    if premium and not premium.get("unlimited") and reset:
        used = 100 - float(premium.get("percent_remaining", 100))
        total = premium.get("entitlement", 0)
        detail = f"{total - premium.get('remaining', 0):g} / {total:g} premium requests"
        windows.append(window("month", used, reset, "month", "outer", detail))
        count = premium.get("overage_count") or 0
        if count:
            overage = {"active": True, "text": f"{count:g} overage requests this month"}
    return {"windows": windows, "overage": overage}


FETCHERS = {
    "claude": fetch_claude,
    "anthropic-credits": fetch_anthropic_credits,
    "opencode-go": fetch_opencode_go,
    "copilot": fetch_copilot,
}


def cache_dir():
    base = os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache"
    return Path(base) / "ai-usage"


def read_cache(pid):
    try:
        entry = json.loads((cache_dir() / f"{pid}.json").read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return None
    return entry if entry.get("version") == CACHE_VERSION else None


def write_cache(pid, entry):
    d = cache_dir()
    d.mkdir(parents=True, exist_ok=True)
    tmp = d / f".{pid}.{os.getpid()}.tmp"
    tmp.write_text(json.dumps({**entry, "version": CACHE_VERSION}))
    tmp.replace(d / f"{pid}.json")


def resolve(p, refresh):
    """Cached or freshly fetched data for provider `p`, never raising.

    The TTL runs from the last attempt, so a failing provider isn't retried on
    every call; a failure keeps the last good windows and records the error.
    """
    cached = read_cache(p["id"])
    t = now()
    if cached and not refresh and t - parse_time(cached["attemptedAt"]) < CACHE_TTL:
        return cached
    try:
        entry = {"attemptedAt": t.isoformat(), "fetchedAt": t.isoformat(), "error": None, **FETCHERS[p["kind"]](p)}
    except Exception as e:  # One provider's failure must not hide the others.
        msg = str(e) if isinstance(e, FetchError) else f"{type(e).__name__}: {e}"
        last = cached or {"fetchedAt": None, "windows": [], "overage": None}
        entry = {**last, "attemptedAt": t.isoformat(), "error": msg}
    write_cache(p["id"], entry)
    return entry


def pace(w, t):
    """Add the elapsed share, the linear projection to reset, and the pace status.

    Over pace means the projection passes 100%; `runsOutAt` is then when the
    current rate hits 100%.
    """
    start, end = parse_time(w["startsAt"]), parse_time(w["resetsAt"])
    total = (end - start).total_seconds()
    since = max(0.0, (t - start).total_seconds())
    elapsed = min(100.0, since / total * 100) if total > 0 else 100.0
    used = w["usedPct"]
    projected = used / elapsed * 100 if elapsed >= MIN_ELAPSED_PCT else None
    runs_out = None
    if used >= 100:
        status = "exhausted"
    elif projected is not None and projected > 100 and used >= MIN_USED_PCT:
        status = "over"
        runs_out = (start + timedelta(seconds=since * 100 / used)).isoformat()
    else:
        status = "under"
    return {
        **w,
        "elapsedPct": round(elapsed, 1),
        "projectedPct": None if projected is None else round(projected),
        "runsOutAt": runs_out,
        "pace": status,
    }


def collect(config, refresh):
    providers = config.get("providers", [])
    with ThreadPoolExecutor(max_workers=max(1, len(providers))) as pool:
        entries = list(pool.map(lambda p: resolve(p, refresh), providers))
    t = now()
    out = []
    for p, e in zip(providers, entries):
        out.append({
            "id": p["id"],
            "name": p["name"],
            "short": p.get("short", p["name"][:2]),
            "icon": p.get("icon"),
            "badge": p.get("badge"),
            "fetchedAt": e.get("fetchedAt"),
            # Stale: last good data served because the latest fetch failed.
            "stale": bool(e.get("error")) and bool(e.get("windows")),
            "error": e.get("error"),
            "windows": [pace(w, t) for w in e.get("windows", [])],
            "overage": e.get("overage"),
            "credit": e.get("credit"),
        })
    return {"generatedAt": t.isoformat(), "providers": out}


def human_delta(seconds):
    seconds = max(0, int(seconds))
    d, rem = divmod(seconds, 86400)
    h, rem = divmod(rem, 3600)
    m = rem // 60
    if d:
        return f"{d}d{h}h"
    if h:
        return f"{h}h{m:02d}m"
    return f"{m}m"


def render(result, color):
    def c(code, s):
        return f"\033[{code}m{s}\033[0m" if color else s

    pace_color = {"under": "32", "over": "33", "exhausted": "31"}
    t = parse_time(result["generatedAt"])
    lines = []
    for p in result["providers"]:
        status = ""
        if p["error"]:
            status = c("33" if p["stale"] else "31", f"  {'stale: ' if p['stale'] else ''}{p['error']}")
        lines.append(c("1", p["name"]) + status)
        for w in p["windows"]:
            filled = round(min(100, w["usedPct"]) / 10)
            bar = c(pace_color[w["pace"]], "█" * filled) + c("2", "░" * (10 - filled))
            resets = parse_time(w["resetsAt"])
            left = human_delta((resets - t).total_seconds())
            when = resets.astimezone().strftime("%a %H:%M")
            projection = f"→{w['projectedPct']}%" if w["projectedPct"] is not None else ""
            if w["runsOutAt"]:
                projection += " out " + parse_time(w["runsOutAt"]).astimezone().strftime("%a %H:%M")
            lines.append(
                f"  {w['label']:<6} {bar} {w['usedPct']:5.1f}% "
                + c(pace_color[w["pace"]] if w["pace"] != "under" else "2", f"{projection:<20}")
                + c("2", f"{w.get('detail') or '':<12} resets {when} (in {left})")
            )
        if p["overage"]:
            o = p["overage"]
            lines.append("  " + (c("31", o["text"]) if o["active"] else c("2", o["text"])))
    return "\n".join(lines)


def main():
    default_config = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config") / "ai-usage" / "config.json"
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--json", action="store_true", help="print JSON instead of a table")
    parser.add_argument("--refresh", action="store_true", help="ignore the cache TTL")
    parser.add_argument("--config", type=Path, default=default_config)
    args = parser.parse_args()
    try:
        config = json.loads(args.config.read_text())
    except FileNotFoundError:
        sys.exit(f"ai-usage: no config at {args.config}")
    result = collect(config, args.refresh)
    if args.json:
        json.dump(result, sys.stdout)
        print()
    else:
        print(render(result, sys.stdout.isatty()))


if __name__ == "__main__":
    main()
