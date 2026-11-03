"""A stand-in for `gh` and `gh stack`, answering from JSON files in $FAKE_GH_DIR.

State: prs.json (list of PRs), merged.json ([branch, sha] pairs GitHub reports as merged),
rules.json (branch rules), stack.json (`gh stack view --json`). Every call is appended to
calls.jsonl so a test can see what was asked. FAKE_GH_FAIL=1 makes every call fail.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

STATE = Path(os.environ["FAKE_GH_DIR"])


def load(name: str, default):
    path = STATE / name
    return json.loads(path.read_text()) if path.exists() else default


def save(name: str, value) -> None:
    (STATE / name).write_text(json.dumps(value))


def sha(ref: str) -> str:
    return subprocess.run(["git", "rev-parse", ref], capture_output=True, text=True, check=True).stdout.strip()


def fail(message: str, code: int = 1) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(code)


def new_pr(prs: list, branch: str, draft: bool) -> dict:
    pr = {
        "number": len(prs) + 1,
        "state": "OPEN",
        "isDraft": draft,
        "url": f"https://example.invalid/pull/{len(prs) + 1}",
        "headRefName": branch,
        "headRefOid": sha(branch),
        "mergeable": "MERGEABLE",
        "statusCheckRollup": [],
        "baseRefName": "main",
    }
    prs.append(pr)
    return pr


def merge(prs: list, pr: dict) -> None:
    pr["state"] = "MERGED"
    merged = load("merged.json", [])
    merged.append([pr["headRefName"], pr["headRefOid"]])
    save("merged.json", merged)


def main(argv: list[str]) -> None:
    with (STATE / "calls.jsonl").open("a") as log:
        log.write(json.dumps(argv) + "\n")
    if os.environ.get("FAKE_GH_FAIL"):
        fail("To get started with GitHub CLI, please run:  gh auth login", 4)
    prs = load("prs.json", [])
    head = argv[:2]
    if head == ["pr", "list"]:
        print(json.dumps([{"headRefName": b, "headRefOid": s} for b, s in load("merged.json", [])]))
    elif head == ["pr", "view"]:
        ref = argv[2]
        found = [pr for pr in prs if ref in (pr["headRefName"], str(pr["number"]))]
        if not found:
            fail(f'no pull requests found for branch "{ref}"')
        print(json.dumps(found[-1]))
    elif head == ["pr", "create"]:
        pr = new_pr(prs, argv[argv.index("--head") + 1], "--draft" in argv)
        save("prs.json", prs)
        print(pr["url"])
    elif head == ["pr", "ready"]:
        number = argv[-1]
        for pr in prs:
            if str(pr["number"]) == number:
                pr["isDraft"] = "--undo" in argv
        save("prs.json", prs)
    elif head == ["pr", "merge"]:
        if "--auto" not in argv:
            for pr in prs:
                if str(pr["number"]) == argv[2]:
                    merge(prs, pr)
            save("prs.json", prs)
    elif argv[0] == "api":
        if argv[1].endswith("/rules/branches/main"):
            print(json.dumps(load("rules.json", [])))
        else:
            fail("gh: Branch not protected (HTTP 404)")
    elif head == ["stack", "view"]:
        stack = load("stack.json", None)
        if stack is None:
            fail('✗ current branch is not part of a stack', 2)
        print(json.dumps(stack))
    elif head == ["stack", "submit"]:
        stack = load("stack.json", {})
        for branch in stack.get("branches", []):
            if not branch.get("pr"):
                pr = new_pr(prs, branch["name"], "--open" not in argv)
                branch["pr"] = {"number": pr["number"], "url": pr["url"], "state": "OPEN"}
        save("stack.json", stack)
        save("prs.json", prs)
    elif head == ["stack", "merge"]:
        stack = load("stack.json", {})
        for branch in stack.get("branches", []):
            for pr in prs:
                if pr["number"] == (branch.get("pr") or {}).get("number"):
                    pr["headRefOid"] = sha(branch["name"])
                    merge(prs, pr)
                    branch["pr"]["state"] = "MERGED"
        save("stack.json", stack)
        save("prs.json", prs)
    else:
        fail(f"fake gh: unhandled {argv}")


if __name__ == "__main__":
    main(sys.argv[1:])
