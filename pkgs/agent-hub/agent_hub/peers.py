"""Working trees: which one a session is in, the repo and branch a digest names, and the
note a session gets about the others sharing its tree."""

import asyncio
import hashlib
import os
import subprocess

# A peer idle this briefly over uncommitted changes is likely between prompts of one task.
RECENT_IDLE_MS = 10 * 60_000
GIT_TIMEOUT = 2


def short_id(socket_path):
    """Claude's own `[ref]` for a session, as both agents' messaging tools resolve it."""
    return hashlib.sha256(f"session:{socket_path}".encode()).hexdigest()[:6]


def note(agent, root, others, dirty, worktree_tool, now):
    """What a session is told about the others in its working tree (registry entries), in
    its own agent's tool names. `dirty` is whether the checkout has uncommitted changes.
    Names only: a summary or idle time changes every turn and would re-key pi's cached
    system prompt."""
    send, enter = ("send_message", "enter_worktree") if agent == "pi" else ("SendMessage", "EnterWorktree")

    def busy(entry):
        if entry.get("status") in ("busy", "waiting"):
            return True
        last = now if entry.get("status") != "idle" else (entry.get("statusUpdatedAt") or entry.get("updatedAt") or entry.get("startedAt") or 0)
        return dirty and now - last <= RECENT_IDLE_MS

    def line(entry):
        harness = "pi" if entry.get("entrypoint") == "pi" else "claude-code"
        return f"- {entry.get('name') or 'pid ' + str(entry.get('pid'))} [{short_id(entry['messagingSocketPath'])}] ({harness})"

    working = [line(e) for e in others if busy(e)]
    still = [line(e) for e in others if not busy(e)]
    lines = [f"Other agent sessions are open in this working tree ({root})."]
    if working:
        lines += ["Working in it now:", *working]
        if dirty:
            lines.append("You share uncommitted changes with them.")
    if still:
        lines += ["Open but not working now:", *still]
    # An open peer still reasons about this branch, so only the worktree push waits for a busy one.
    lines.append(f"Before you commit, switch branches, rebase, merge, or run git checkout/restore/reset/stash/clean, tell them with {send}.")
    if working and worktree_tool:
        lines.append(f"For more than a quick edit, {enter} gives you a checkout of your own.")
    if dirty or working:
        lines.append("Changes in git status that you did not make are probably theirs: never revert, stash or commit them; "
                     "ask your user instead.")
    return "\n".join(lines)


class Git:
    def __init__(self, exe):
        self.exe = exe or "git"
        # cwd → its working tree's root: a directory's tree doesn't move.
        self.roots = {}

    def _run(self, cwd, *args):
        try:
            out = subprocess.run([self.exe, "-C", cwd, *args], capture_output=True, text=True, timeout=GIT_TIMEOUT)
        except (OSError, subprocess.TimeoutExpired):
            return None
        return out.stdout.strip() if out.returncode == 0 else None

    async def dirty(self, root):
        """Whether the checkout at `root` has uncommitted changes; False when git can't tell."""
        # --no-optional-locks: don't take the index lock under a peer mid-edit.
        try:
            out = await asyncio.to_thread(subprocess.run, [self.exe, "--no-optional-locks", "-C", root, "status", "--porcelain"],
                                          capture_output=True, text=True, timeout=GIT_TIMEOUT)
        except (OSError, subprocess.TimeoutExpired):
            return False
        return out.returncode == 0 and bool(out.stdout.strip())

    async def root(self, cwd):
        """The working tree a directory is in, or the directory itself outside git."""
        if not cwd:
            return None
        if cwd not in self.roots:
            self.roots[cwd] = await asyncio.to_thread(self._run, cwd, "rev-parse", "--show-toplevel") or os.path.realpath(cwd)
        return self.roots[cwd]

    async def context(self, cwd, digest):
        """Names the repo and branch in `digest`, unless it already does."""
        if digest.get("repo"):
            return
        root = await self.root(cwd)
        if root:
            digest["repo"] = os.path.basename(root)
            digest["branch"] = await asyncio.to_thread(self._run, cwd, "branch", "--show-current") or ""
