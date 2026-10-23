"""Print quota windows (and credit balances) for AI agent subscriptions.

Output is a table, or JSON with --json.

Providers come from $XDG_CONFIG_HOME/ai-usage/config.json (written by the
ai-usage home-manager leaf). Each provider's last result is cached per id for
CACHE_TTL; a failed fetch serves the cached result marked stale. Credentials
are only ever read, never refreshed or written.
"""

import argparse
import calendar
import email.utils
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

CACHE_TTL = timedelta(minutes=2)
# Bump when the cached entry shape changes, so an upgrade discards old entries.
CACHE_VERSION = 4
TIMEOUT = 10
# Projections from the first few % of a window, or from trivial usage, are noise.
MIN_ELAPSED_PCT = 5
MIN_USED_PCT = 10
CURRENCY_SYMBOLS = {"EUR": "€", "USD": "$", "GBP": "£"}
# Synthetic refills its weekly credit meter in 2% steps, one every 202 minutes,
# so a spent meter is full again one week later. A meter has no window to be on
# pace with, so it is reported as one (`meter`) and warned on by what is left.
SYNTHETIC_TICK = timedelta(minutes=202)
SYNTHETIC_STEP_PCT = 2.0
# Past this share a meter is nearly spent: at 2% per 202 minutes it is under a
# day of regeneration from empty, which is the last point worth warning at.
METER_WARN_PCT = 80.0


class FetchError(Exception):
    """A provider fetch that failed; `retry_after` is the wait the server asked for."""

    def __init__(self, message, retry_after=None):
        super().__init__(message)
        self.retry_after = retry_after


def now():
    return datetime.now(timezone.utc)


def parse_time(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def month_before(t):
    year, month = (t.year, t.month - 1) if t.month > 1 else (t.year - 1, 12)
    # Clamp to the shorter month (e.g. 31 Mar -> 28/29 Feb).
    return t.replace(year=year, month=month, day=min(t.day, calendar.monthrange(year, month)[1]))


def money(amount, currency):
    text = f"{amount:.2f}".removesuffix(".00")
    symbol = CURRENCY_SYMBOLS.get(currency)
    return f"{symbol}{text}" if symbol else f"{text} {currency}".rstrip()


def keeps(p, key):
    """A provider's `windows` list, when present, is the allowlist of raw window keys."""
    wanted = p.get("windows")
    return not wanted or key in wanted


def window(label, used_pct, resets_at, length, ring=None, detail=None, starts=None, meter=False):
    """A quota window; `length` is a timedelta, or "month" for a calendar month.

    `meter` marks a budget that regenerates instead of resetting: `resets_at` is
    then the next top-up, not a turnover, and nothing is on pace.
    """
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
        "meter": meter,
    }


def retry_after(error):
    """Seconds from a Retry-After header, which is either a count or an HTTP date."""
    value = error.headers.get("Retry-After") if error.headers else None
    if not value:
        return None
    try:
        return max(0.0, float(value))
    except ValueError:
        pass
    try:
        when = email.utils.parsedate_to_datetime(value)
    except (TypeError, ValueError):
        return None
    return max(0.0, (when - now()).total_seconds())


def http_json(url, headers):
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as e:
        raise FetchError(f"HTTP {e.code}", retry_after=retry_after(e)) from e
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


def fetch_anthropic_credits(p):
    """Live balance of the Console's promotional credit grants (the Max plan's API credit).

    Anthropic has no API-key route to the balance, so this reads the Console's own
    undocumented endpoint with the browser `sessionKey` cookie. The Admin cost report
    is no substitute: it only covers finished UTC days.
    """
    session = Path(p["sessionKeyFile"]).read_text().strip()
    try:
        data = http_json(
            f"https://platform.claude.com/api/organizations/{p['orgId']}/prepaid/credits",
            {"Cookie": f"sessionKey={session}", "User-Agent": "ai-usage"},
        )
    except FetchError as e:
        if str(e) in ("HTTP 401", "HTTP 403"):
            raise FetchError(f"console session rejected ({e}); refresh the sessionKey secret") from e
        raise
    grants = data.get("promo_tranches") or []
    if not grants:
        raise FetchError("no credit grant")
    # Minor units, like the top-level `amount`.
    allowance = sum(g["granted_amount_minor_units"] for g in grants) / 100
    remaining = sum(g["remaining_amount_minor_units"] for g in grants) / 100
    currency = grants[0].get("currency") or "USD"
    starts = min(parse_time(g["granted_at"]) for g in grants)
    resets = min(parse_time(g["expires_at"]) for g in grants)
    spent = allowance - remaining
    used = spent / allowance * 100 if allowance else 0
    detail = f"{money(spent, currency)} of {money(allowance, currency)} spent"
    return {
        "windows": [window("credit", used, resets, "month", "outer", detail, starts)],
        "overage": None,
        "credit": {
            "remaining": round(remaining, 2),
            "allowance": allowance,
            "currency": currency,
        },
    }


def number(value):
    """A /v2/quotas amount, some of which it writes as dollars ("$2.10")."""
    try:
        return float(str(value).lstrip("$").strip())
    except (TypeError, ValueError):
        return None


def fetch_synthetic(p):
    """The weekly credit meter on /v2/quotas, plus the rolling burst cap beside it.

    Synthetic regenerates credits instead of resetting them: the plan reports
    what is left and when the next slice lands, where a slice is a percentage
    (`nextRegenPercent`) or a dollar amount (`nextRegenCredits`) of the weekly
    limit. So the meter is reported as a `meter`, with `resetsAt` at the next
    top-up. `subscription` is left out: it is a legacy request counter that only
    some accounts still populate, and it is not what blocks a request.
    """
    key = Path(p["keyFile"]).read_text().strip()
    data = http_json(
        "https://api.synthetic.new/v2/quotas",
        {"Authorization": f"Bearer {key}", "User-Agent": "ai-usage"},
    )
    t = now()
    windows = []
    burst = data.get("rollingFiveHourLimit") or {}
    if keeps(p, "rolling") and number(burst.get("max")):
        limit = number(burst["max"])
        used = (limit - (number(burst.get("remaining")) or 0)) / limit * 100
        windows.append(
            window(
                "5h",
                # The endpoint's own verdict, which outranks the arithmetic.
                100.0 if burst.get("limited") else used,
                burst.get("nextTickAt") or t,
                timedelta(hours=5),
                "outer",
            )
        )
    weekly = data.get("weeklyTokenLimit") or data.get("planWeeklyLimit") or {}
    allowance = number(weekly.get("maxCredits"))
    left = number(weekly.get("remainingCredits"))
    remaining = number(weekly.get("percentRemaining"))
    if remaining is None and allowance and left is not None:
        remaining = left / allowance * 100
    if keeps(p, "weekly") and remaining is not None:
        used = 100 - remaining
        step = number(weekly.get("nextRegenPercent"))
        if step is None and allowance and number(weekly.get("nextRegenCredits")) is not None:
            step = number(weekly["nextRegenCredits"]) / allowance * 100
        detail = (
            f"{money(left, 'USD')} of {money(allowance, 'USD')} left"
            if None not in (left, allowance)
            else None
        )
        windows.append(
            window(
                "7d",
                used,
                # Without a tick time, one step's worth of spend is a tick's wait.
                weekly.get("nextRegenAt") or t + SYNTHETIC_TICK * (used / (step or SYNTHETIC_STEP_PCT)),
                timedelta(days=7),
                "inner" if windows else "outer",
                detail,
                meter=True,
            )
        )
    if not windows:
        raise FetchError("no quota in the answer")
    return {"windows": windows, "overage": None}


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


def kimi_reset(data, t):
    """A pool's turnover: an absolute timestamp, or a number of seconds from now.

    A value that is neither leaves the pool unreadable, so the caller skips that
    window rather than failing the whole fetch.
    """
    for key in ("reset_time", "resetTime", "reset_at", "resetAt"):
        value = data.get(key)
        if value is None:
            continue
        try:
            return parse_time(str(value))
        except ValueError:
            continue
    for key in ("reset_in", "resetIn", "ttl"):
        seconds = number(data.get(key))
        if seconds and seconds > 0:
            return t + timedelta(seconds=seconds)
    return None


def kimi_pool(pool, t):
    """(used_pct, resets_at) from a `usages` entry, whose `used_ratio` is 0-1."""
    if not isinstance(pool, dict):
        return None
    ratio = number(pool.get("used_ratio"))
    resets = kimi_reset(pool, t)
    if ratio is None or resets is None:
        return None
    # 1.0 is 100% used; a payload that spells the ratio as a percent is tolerated.
    return (ratio if ratio <= 1 else ratio / 100) * 100, resets


def kimi_window(entry, detail, t):
    """A `limits` entry as (seconds, label, used_pct, resets_at, length, text).

    `seconds` orders windows from shortest to longest and `text` is the "used of
    limit" line. The window names its own size
    (`{"duration": 300, "timeUnit": "TIME_UNIT_MINUTE"}`), so a plan that adds or
    drops one needs no change here.
    """
    span = entry.get("window") if isinstance(entry.get("window"), dict) else {}
    duration = number(span.get("duration"))
    unit = str(span.get("timeUnit") or span.get("unit") or "").upper()
    if duration:
        if "MINUTE" in unit:
            length, seconds = timedelta(minutes=duration), duration * 60
            label = f"{duration / 60:g}h"
        elif "HOUR" in unit:
            length, seconds = timedelta(hours=duration), duration * 3600
            label = f"{duration:g}h"
        elif "DAY" in unit:
            length, seconds = timedelta(days=duration), duration * 86_400
            label = f"{duration:g}d"
        elif "MONTH" in unit:
            length, seconds, label = "month", duration * 30 * 86_400, "month"
        else:
            return None
    else:
        return None

    limit = number(detail.get("limit"))
    used = number(detail.get("used"))
    if used is None and limit is not None:
        remaining = number(detail.get("remaining"))
        used = None if remaining is None else limit - remaining
    resets = kimi_reset(detail, t) or kimi_reset(entry, t)
    if used is None or not limit or resets is None:
        return None
    text = f"{used:g} of {limit:g} used"
    return seconds, label, used / limit * 100, resets, length, text


def kimi_limits(entries, t):
    rows = []
    for entry in entries or []:
        if not isinstance(entry, dict):
            continue
        detail = entry.get("detail") if isinstance(entry.get("detail"), dict) else entry
        row = kimi_window(entry, detail, t)
        if row:
            rows.append(row)
    rows.sort(key=lambda row: row[0])
    return [
        window(label, used, resets, length, ("outer", "inner")[i] if i < 2 else None, text)
        for i, (_, label, used, resets, length, text) in enumerate(rows)
    ]


def fetch_kimi_coding(p):
    """The Kimi Code plan's quota on /coding/v1/usages: the rolling five-hour
    rate window and the monthly pool every membership feature shares.

    Both are `usages` entries, a 0-1 `used_ratio` plus an absolute `reset_time`.
    The `limits` array beside them repeats the five-hour window in
    used/remaining form, so it is only the fallback for an older payload.
    """
    key = Path(p["keyFile"]).read_text().strip()
    data = http_json(
        "https://api.kimi.com/coding/v1/usages",
        {"Authorization": f"Bearer {key}", "User-Agent": "ai-usage"},
    )
    t = now()
    pools = data.get("usages") if isinstance(data.get("usages"), dict) else {}
    windows = []
    for name, label, length, ring in (
        ("limit_5h", "5h", timedelta(hours=5), "outer"),
        ("limit_month_total", "month", "month", "inner"),
    ):
        pool = kimi_pool(pools.get(name), t)
        if pool is None:
            # Everything shares the monthly pool; the Code-only counter is the
            # same quota under another name, so either one will do.
            pool = kimi_pool(pools.get("limit_month_code"), t) if length == "month" else None
        if pool is None:
            continue
        used, resets = pool
        windows.append(window(label, used, resets, length, ring))
    if not windows:
        windows = kimi_limits(data.get("limits"), t)
    if not windows:
        raise FetchError("no quota windows in the answer")
    return {"windows": windows, "overage": None}


FETCHERS = {
    "claude": fetch_claude,
    "anthropic-credits": fetch_anthropic_credits,
    "opencode-go": fetch_opencode_go,
    "synthetic": fetch_synthetic,
    "kimi-coding": fetch_kimi_coding,
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
    every call; a failure keeps the last good windows and records the error. A
    server that answered with Retry-After is left alone until then even by a
    forced refresh, because asking again is only another 429.
    """
    cached = read_cache(p["id"])
    t = now()
    if cached and cached.get("retryAt") and parse_time(cached["retryAt"]) > t:
        return cached
    if cached and not refresh and t - parse_time(cached["attemptedAt"]) < CACHE_TTL:
        return cached
    try:
        entry = {"attemptedAt": t.isoformat(), "fetchedAt": t.isoformat(), "error": None, **FETCHERS[p["kind"]](p)}
    except Exception as e:  # One provider's failure must not hide the others.
        msg = str(e) if isinstance(e, FetchError) else f"{type(e).__name__}: {e}"
        last = cached or {"fetchedAt": None, "windows": [], "overage": None}
        entry = {k: v for k, v in last.items() if k not in ("retryAt", "version")}
        entry.update({"attemptedAt": t.isoformat(), "error": msg})
        wait = getattr(e, "retry_after", None)
        if wait:
            entry["retryAt"] = (t + timedelta(seconds=wait)).isoformat()
            entry["error"] = f"{msg}, retrying in {human_delta(wait)}"
    write_cache(p["id"], entry)
    return entry


def pace(w, t):
    """Add the elapsed share, the linear projection to reset, and the pace status.

    Over pace means the projection passes 100%; `runsOutAt` is then when the
    current rate hits 100%. A meter has no window to project across, so it only
    warns: over once spent past the warn threshold, out at 100%.
    """
    if w.get("meter"):
        used = w["usedPct"]
        status = "exhausted" if used >= 100 else "over" if used >= METER_WARN_PCT else "under"
        return {**w, "elapsedPct": 0.0, "projectedPct": None, "runsOutAt": None, "pace": status}
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
            moves = "top-up" if w["meter"] else "resets"
            lines.append(
                f"  {w['label']:<6} {bar} {w['usedPct']:5.1f}% "
                + c(pace_color[w["pace"]] if w["pace"] != "under" else "2", f"{projection:<20}")
                + c("2", f"{w.get('detail') or '':<12} {moves} {when} (in {left})")
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
