"""The menus a session's folder and branch open in the popout, pi's footer menus (its
chrome/places.ts, links.ts and remote.ts) for a row: this checkout in the apps this desktop
runs, where its branch lives on the web, and the pull request it is waiting on or still needs.

Every row is a link, a copy or an app opening a folder, so a click never pushes, rebases or
creates anything. An app that can't run keeps its row and says why, so the menu reads the same
on every host. `facts` runs where the session does; everything built from them runs at the
viewer, which trusts nothing the other host says about a URL.
"""

import asyncio
import json
import re
import subprocess
from urllib.parse import quote, urlsplit

# GitHub, GitLab and Codeberg only: guessing another forge's layout makes links that look right and 404.
FORGES = {"github.com": "github", "gitlab.com": "gitlab", "codeberg.org": "codeberg"}
SEGMENT = re.compile(r"[A-Za-z0-9._-]+")
SHORT_SHA = 7
GIT_TIMEOUT = 3
GH_TIMEOUT = 8
APPS = (("code", "VS Code"), ("smerge", "Sublime Merge"), ("files", "Files"), ("ghostty", "Ghostty"))


def parse_remote(raw):
    """A remote URL as a forge knows it, `{forge, host, owner, repo, web}`, or None for a host or
    a path this doesn't know."""
    trimmed = str(raw or "").strip().rstrip("/").removesuffix(".git")
    if re.match(r"^[a-z][a-z0-9+.-]*://", trimmed, re.I):
        try:
            parts = urlsplit(trimmed)
            host, path = parts.hostname or "", parts.path
        except ValueError:
            return None
    else:
        # The scp-like form git writes for SSH: [user@]host:path.
        match = re.fullmatch(r"(?:[^@/]+@)?([^:/]+):(.+)", trimmed)
        if not match:
            return None
        host, path = match.groups()
    forge = FORGES.get(host.lower())
    segments = [segment for segment in path.split("/") if segment]
    if not forge or len(segments) < 2 or not all(SEGMENT.fullmatch(segment) for segment in segments):
        return None
    owner, repo = "/".join(segments[:-1]), segments[-1]
    return {"forge": forge, "host": host.lower(), "owner": owner, "repo": repo, "web": f"https://{host.lower()}/{owner}/{repo}"}


def branch_url(remote, branch):
    leaf = quote(branch)
    return {"github": f"{remote['web']}/tree/{leaf}", "gitlab": f"{remote['web']}/-/tree/{leaf}",
            "codeberg": f"{remote['web']}/src/branch/{leaf}"}[remote["forge"]]


def commit_url(remote, sha):
    middle = "/-/commit/" if remote["forge"] == "gitlab" else "/commit/"
    return f"{remote['web']}{middle}{quote(sha)}"


def compare_url(remote, base, branch):
    """GitHub's compare form with the pull request fields open, which never offers to push."""
    return f"{remote['web']}/compare/{quote(base)}...{quote(branch)}?expand=1"


def facts(exe, cwd):
    """What git says of a checkout, for building its menu wherever you are looking from. The
    remote is the branch's upstream, then `origin`, then the only supported one: where the
    branch is published rather than where the session sits."""

    def git(*args):
        try:
            out = subprocess.run([exe, "--no-optional-locks", "-C", cwd, *args], capture_output=True, text=True, timeout=GIT_TIMEOUT)
        except (OSError, subprocess.SubprocessError):
            return ""
        return out.stdout.strip() if out.returncode == 0 else ""

    branch = git("branch", "--show-current")
    urls = {}
    for line in git("config", "--get-regexp", r"^remote\..*\.url$").splitlines():
        match = re.fullmatch(r"remote\.(.+)\.url\s+(.+)", line.strip())
        # A remote with separate fetch and push URLs lists both; people read the fetch one.
        if match and parse_remote(match[2]):
            urls.setdefault(match[1], match[2])
    via = git("config", "--get", f"branch.{branch}.remote") if branch else ""
    name = via if via in urls else "origin" if "origin" in urls else next(iter(urls)) if len(urls) == 1 else ""
    base = git("config", "--get", f"branch.{branch}.gh-merge-base") if branch else ""
    if not base and name:
        head = git("symbolic-ref", "--quiet", "--short", f"refs/remotes/{name}/HEAD")
        known = (c for c in ("main", "master") if git("rev-parse", "--verify", "--quiet", f"refs/remotes/{name}/{c}"))
        base = head.removeprefix(f"{name}/") if head.startswith(f"{name}/") else next(known, "")
    return {"branch": branch, "oid": git("rev-parse", "HEAD"), "upstream": bool(git("rev-parse", "--abbrev-ref", "@{u}")),
            "remote": urls.get(name, ""), "base": base or "main"}


async def pull_request(gh, remote, branch):
    """(the branch's pull request or None, whether gh could say, whether gh is missing)."""
    if not gh:
        return None, False, True
    proc = None
    try:
        proc = await asyncio.create_subprocess_exec(
            gh, "pr", "list", f"--repo={remote['owner']}/{remote['repo']}", f"--head={branch}", "--state=all", "--limit=1",
            "--json=number,url,state,isDraft", stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
        )
        out, _ = await asyncio.wait_for(proc.communicate(), GH_TIMEOUT)
        found = json.loads(out)
    except OSError:
        return None, False, True
    except (asyncio.TimeoutError, ValueError):
        if proc and proc.returncode is None:
            proc.kill()
        return None, False, False
    if proc.returncode != 0 or not isinstance(found, list):
        return None, False, False
    if not found:
        return None, True, False
    pr = found[0]
    url = str(pr.get("url") or "")
    if not url.startswith(remote["web"] + "/"):
        return None, True, False
    state = "draft" if pr.get("isDraft") else str(pr.get("state") or "").lower()
    return {"number": pr.get("number"), "url": url, "state": state}, True, False


def url_row(row_id, label, url, **fields):
    return {"id": row_id, "label": label, "run": {"kind": "url", "value": url}, **fields}


def copy_row(row_id, label, value):
    return {"id": row_id, "label": label, "run": {"kind": "copy", "value": value}}


def blocked_row(row_id, label, why):
    return {"id": row_id, "label": label, "unavailable": why}


def git_menu(found, pr=None, pr_known=False, gh_missing=False):
    """The git menu of a checkout, from its `facts`. What it can't reach says so in a few words."""
    remote = parse_remote(found.get("remote"))
    branch, oid, base = found.get("branch") or "", found.get("oid") or "", found.get("base") or "main"
    rows = [url_row("repo", "Open repository", remote["web"], description=remote["host"]) if remote
            else blocked_row("repo", "Open repository", "no supported remote")]
    if branch:
        rows.append(url_row("branch", "Open branch", branch_url(remote, branch)) if remote
                    else blocked_row("branch", "Open branch", "no supported remote"))
    elif oid:
        label = f"Open commit {oid[:SHORT_SHA]}"
        rows.append(url_row("commit", label, commit_url(remote, oid)) if remote else blocked_row("commit", label, "no supported remote"))
    if pr:
        rows.append(url_row("pr", f"Open pull request #{pr['number']}", pr["url"], description=pr["state"]))
    rows.append(_create_row(found, remote, pr, pr_known, gh_missing))
    rows.append(copy_row("copy", "Copy branch name", branch) if branch else copy_row("copy", "Copy commit SHA", oid))
    if pr:
        rows.append(copy_row("copy-pr", "Copy PR URL", pr["url"]))
    # The pull request is what a git click is usually after, then the branch, then the repository.
    preferred = "pr" if pr else "repo" if not remote else "branch" if branch else "commit"
    context = f"{remote['owner']}/{remote['repo']}" if remote else ""
    return {"title": "Git", "context": context, "preferred": preferred, "rows": rows}


def _create_row(found, remote, pr, pr_known, gh_missing):
    branch, base = found.get("branch") or "", found.get("base") or "main"
    label = "Create new pull request" if pr and pr["state"] in ("merged", "closed") else "Create pull request"
    if not remote:
        why = "no supported remote"
    elif remote["forge"] != "github":
        why = "GitHub only"
    elif not branch:
        why = "detached HEAD"
    elif pr and pr["state"] in ("open", "draft"):
        why = f"PR #{pr['number']} is open"
    elif not found.get("upstream"):
        why = "push the branch first"
    elif not pr_known:
        why = "gh not installed" if gh_missing else "still asking gh"
    else:
        return url_row("create", label, compare_url(remote, base, branch), description=f"into {base}")
    return blocked_row("create", label, why)


def folder_menu(cwd, host, can_run):
    """The folder menu. From another host the folder is out of reach of what can't go over ssh,
    so those rows say where it is. `can_run` says whether an app runs on this desktop."""
    over_ssh = ("code", "ghostty")

    def row(app, label):
        if not can_run(app):
            return blocked_row(app, label, "not installed")
        if host and app not in over_ssh:
            return blocked_row(app, label, f"on {host}")
        return {"id": app, "label": label, "run": {"kind": "app", "value": app}}

    rows = [row(app, label) for app, label in APPS]
    # The editor is where the work continues, so it leads when it can run.
    preferred = "code" if "run" in rows[0] else ""
    return {"title": "Open folder", "context": "", "preferred": preferred, "rows": [*rows, copy_row("copy", "Copy path", cwd)]}
