#!/usr/bin/env python3
"""Turn the published agents-updates state into what one agent profile actually loads.

`fireproof.agents.updates` pins agents' plugins and skills from the flake input and lets
`agents update NAME` publish a newer snapshot into `current.json`; nothing is ever linked from
a checkout. Neither harness can be handed new plugin paths by another process, so this runs
where a launch or a session's own reload request can reach it: the pi launcher, the pi bridge
(through AGENTS_REFRESH), claude's launcher and home-manager's activation. It reloads nothing
itself — pi's bridge calls `ctx.reload()` afterwards, and claude needs a restart.

What it owns in a profile, and nothing else:

What it owns in a profile, and nothing else:

  <profile>/settings.json    pi only: `skills`, the managed entries of `packages`, and
                             `piAgents.twinExtensions`. Third-party packages, `parent/`,
                             `${extensions}/core` and anything a user added are left alone.
                             Twins stay the pinned set: a published plugin is not promoted to
                             a durable agent's tool twin. Skill resources are canonical store
                             paths, so a reload re-reads them and a running session's loaded
                             metadata keeps the paths it started with.
  <profile>/skills/          claude only: a view (symlinks, mode 0555) of the effective skill
                             map, since Claude Code discovers skills in its config dir. It is
                             per profile, not per session: a publication only reaches a
                             launch, and a refresh rewrites the one view every session in that
                             profile reads at its next start. Two sessions in the same profile
                             are therefore not isolated from each other.

Env (set by agent-skills.nix and the harness modules):

  AGENTS_HARNESS               pi | claude
  AGENTS_PROFILE               the config root to manage (pi's agent dir, claude's config dir)
  AGENTS_BASELINE, AGENTS_CLI  the CLI's own env, passed straight through to `agents resolve`
  AGENTS_PLUGIN_ORDER          space separated plugin load order
  AGENTS_SKILL_EXTRAS          optional JSON file {name: path}: skills outside the registry
  AGENTS_CLAUDE_ENV            optional JSON file {"env": {...}} the launch settings start from
  AGENTS_CLAUDE_SETTINGS_DIR   where to keep the launch settings; the chosen path is printed
  AGENTS_CLAUDE_EXTRA_SETTINGS optional JSON object merged into those settings
"""

import fcntl
import hashlib
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

PROG = "agents updates"
HARNESSES = ("pi", "claude")
MANIFEST = ".agents-updates.json"
LOCK = ".agents-updates.lock"
TWIN_KEY = "piAgents"
# What a previous generation's links point into: the store, or the checkout the old design
# linked. Only entries like these may be replaced.
STORE_ROOT = "/nix/store/"


class Fail(Exception):
    """A problem worth reporting without a traceback: the caller decides what to do."""


def say(message):
    print(f"{PROG}: {message}", file=sys.stderr)


def read_json(path):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except OSError as exc:
        raise Fail(f"cannot read {path}: {exc.strerror or exc}") from None
    except ValueError as exc:
        raise Fail(f"{path} is not JSON: {exc}") from None


def write_json(path, value, mode=0o600):
    """Atomically, so a session reading the file never sees half of it."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temp.write_text(json.dumps(value, indent=2, sort_keys=False) + "\n", encoding="utf-8")
    os.chmod(temp, mode)
    os.replace(temp, path)


def resolve(env):
    """What both harnesses should load: `agents resolve`, the union of baseline and state."""
    cli = env.get("AGENTS_CLI") or "agents"
    try:
        proc = subprocess.run(
            [cli, "resolve"],
            capture_output=True,
            text=True,
            env=dict(env),
            check=False,
        )
    except OSError as exc:
        raise Fail(f"cannot run {cli}: {exc.strerror or exc}") from None
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout).strip() or f"exit {proc.returncode}"
        raise Fail(f"{cli} resolve failed: {detail}")
    try:
        data = json.loads(proc.stdout)
    except ValueError:
        raise Fail(f"{cli} resolve did not print JSON")
    if (
        not isinstance(data, dict)
        or not isinstance(data.get("plugins"), dict)
        or not isinstance(data.get("skills"), dict)
    ):
        raise Fail(f"{cli} resolve printed an unexpected shape")
    return data


def replaceable(entry, roots):
    """Whether a previous generation wrote this entry: a link into the store (or a checkout), or
    a directory holding nothing else — home-manager's per-file form of a skill directory.
    """
    if entry.is_symlink():
        target = os.readlink(entry)
        return any(target.startswith(root) for root in roots)
    if not entry.is_dir():
        return False
    for child in entry.rglob("*"):
        if child.is_dir() and not child.is_symlink():
            continue
        if not child.is_symlink():
            return False
        if not any(os.readlink(child).startswith(root) for root in roots):
            return False
    return True


def sync_skills(profile, desired, previous, roots):
    """Point `<profile>/skills/<name>` at `desired` for the names this design manages.

    Claude Code discovers skills in this directory and also writes its own synced ones there,
    so the directory stays a real directory and only the per-name entries are ours. An entry a
    previous generation created (home-manager's directory-of-store-links form, or a link into
    a checkout) is replaced; anything else is reported and left in place.
    """
    directory = Path(profile) / "skills"
    directory.mkdir(parents=True, exist_ok=True)
    changed = 0
    for name, target in desired.items():
        link = directory / name
        try:
            if link.is_symlink() and os.readlink(link) == target:
                continue
            if link.is_symlink() or link.exists():
                if not replaceable(link, roots):
                    say(f"{link} was not written by this flake, so {name} was left as it is")
                    continue
                if link.is_dir() and not link.is_symlink():
                    shutil.rmtree(link)
                else:
                    link.unlink()
            os.symlink(target, link)
            changed += 1
        except OSError as exc:
            raise Fail(f"cannot link {link}: {exc.strerror or exc}") from None
    for name in previous - set(desired):
        link = directory / name
        if link.is_symlink() and any(os.readlink(link).startswith(root) for root in roots):
            link.unlink()
            changed += 1
    return changed


def managed_paths(baseline, manifest, key, variants):
    """path -> plugin name, for entries this design wrote: pinned paths and last published ones."""
    owned = {}
    for name, entry in (baseline.get("plugins") or {}).items():
        path = entry.get(variants)
        if path:
            owned[path] = name
    for name, path in (manifest.get(key) or {}).items():
        if path and path not in owned:
            owned[path] = name
    return owned


def rewrite(entries, owned, picked, pinned, field):
    """Replace every owned entry in place, dropping variants that no longer exist.

    A name that the list has never held is inserted after the last owned entry, so a new
    plugin lands beside its siblings instead of after whatever ends the list.
    """
    if not isinstance(entries, list):
        raise Fail(f"{field} is not a list")
    result = []
    seen = set()
    last = None
    for entry in entries:
        if not isinstance(entry, str):
            result.append(entry)
            continue
        name = owned.get(entry)
        if name is None:
            result.append(entry)
            continue
        target = picked.get(name) or pinned.get(name)
        if target is None:
            continue
        result.append(target)
        seen.add(name)
        last = len(result) - 1
    fresh = [picked[name] for name in sorted(picked) if name not in seen and picked[name]]
    if fresh:
        at = len(result) if last is None else last + 1
        result[at:at] = fresh
    wrote = {}
    for name in sorted(seen | set(picked)):
        target = picked.get(name) or pinned.get(name)
        if target:
            wrote[name] = target
    return result, wrote


def sync_pi_skills(settings, desired, baseline, manifest, home):
    """Point pi's skill resources at immutable store paths, in settings.json.

    `settings.skills` loads what it lists and filters what discovery found, so the resolved
    paths are canonical for the session (a reload re-reads this list, a running session's
    already-loaded metadata keeps its own store paths). The registry's own directory is
    excluded name by name instead of dropping the whole directory: anything else in it, every
    project `.agents/skills` dir, and any pattern someone added with `pi config` stays.
    """
    agents_skills = Path(home) / ".agents" / "skills"
    names = set(baseline.get("skills") or {}) | set(desired)
    excluded = [f"-{agents_skills / name}" for name in sorted(names)]
    managed = [desired[name] for name in sorted(desired)] + excluded

    previous = set(manifest.get("skills") or [])
    kept = [
        entry
        for entry in (settings.get("skills") or [])
        if isinstance(entry, str) and entry not in previous and entry not in managed
    ]
    merged = managed + kept
    # Record what this design wrote, not what it merely left alone: a pattern added with
    # `pi config` must survive the next run, and a path of ours that a reset dropped must not.
    manifest["skills"] = managed
    if merged != settings.get("skills"):
        settings["skills"] = merged
        return 1
    return 0


def sync_pi_settings(profile, resolved, baseline, manifest, home, desired_skills):
    """Rewrite only the managed entries of one pi profile's settings.json.

    `manifest` is the caller's, mutated in place: it remembers which paths this design wrote,
    so a path left behind by a `reset` is still recognised as ours and replaced.
    """
    profile = Path(profile)
    settings_path = profile / "settings.json"
    if not settings_path.exists():
        return 0
    settings = read_json(settings_path)
    if not isinstance(settings, dict):
        raise Fail(f"{settings_path} does not hold a JSON object")

    plugins = resolved.get("plugins") or {}
    picked = {
        name: (entry or {}).get("pi")
        for name, entry in plugins.items()
    }
    pinned = {name: (entry or {}).get("pi") for name, entry in (baseline.get("plugins") or {}).items()}

    changed = sync_pi_skills(settings, desired_skills, baseline, manifest, home)
    owned = managed_paths(baseline, manifest, "packages", "pi")
    if "packages" in settings:
        packages, wrote = rewrite(settings["packages"], owned, picked, pinned, "packages")
        if packages != settings["packages"]:
            settings["packages"] = packages
            changed += 1
        manifest["packages"] = wrote

    # Twins are a pinned choice, not something a publication extends: only the names already
    # in the array (or last written there) are refreshed, so a new plugin never becomes a twin.
    agents = settings.get(TWIN_KEY)
    if isinstance(agents, dict) and isinstance(agents.get("twinExtensions"), list):
        twin_owned = managed_paths(baseline, manifest, "twins", "pi")
        current = agents["twinExtensions"]
        twin_names = {twin_owned[entry] for entry in current if entry in twin_owned}
        picked_twins = {name: picked[name] for name in twin_names if picked.get(name)}
        pinned_twins = {name: pinned[name] for name in twin_names if pinned.get(name)}
        twins, wrote = rewrite(current, twin_owned, picked_twins, pinned_twins, "twinExtensions")
        if twins != current:
            agents["twinExtensions"] = twins
            changed += 1
        manifest["twins"] = wrote

    if changed:
        write_json(settings_path, settings)
    return changed


def claude_settings(env, resolved):
    """The launch settings claude needs: the effective plugin dirs over the baseline env.

    The file is content-addressed, so concurrent launches never rewrite one another's file
    (claude reads it once at startup) and an unchanged resolution stops making new ones.
    """
    directory = env.get("AGENTS_CLAUDE_SETTINGS_DIR")
    if not directory:
        return None
    base = {}
    if env.get("AGENTS_CLAUDE_ENV"):
        loaded = read_json(env["AGENTS_CLAUDE_ENV"])
        if isinstance(loaded, dict) and isinstance(loaded.get("env"), dict):
            base = dict(loaded["env"])
    plugins = resolved.get("plugins") or {}
    order = [name for name in (env.get("AGENTS_PLUGIN_ORDER") or "").split() if name]
    ordered = [name for name in order if name in plugins]
    ordered += [name for name in sorted(plugins) if name not in set(order)]
    dirs = [plugins[name].get("claude") for name in ordered if plugins[name].get("claude")]
    base["CLAUDE_CODE_PLUGIN_DIRS"] = ":".join(dirs)
    settings = {"env": base}
    extra = env.get("AGENTS_CLAUDE_EXTRA_SETTINGS")
    if extra:
        try:
            loaded = json.loads(extra)
        except ValueError as exc:
            raise Fail(f"AGENTS_CLAUDE_EXTRA_SETTINGS is not JSON: {exc}") from None
        if not isinstance(loaded, dict):
            raise Fail("AGENTS_CLAUDE_EXTRA_SETTINGS must hold a JSON object")
        settings.update(loaded)

    body = json.dumps(settings, indent=2, sort_keys=False) + "\n"
    digest = hashlib.sha256(body.encode("utf-8")).hexdigest()[:16]
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / f"{digest}.json"
    if not path.exists():
        temp = directory / f".{digest}.{os.getpid()}.tmp"
        temp.write_text(body, encoding="utf-8")
        os.chmod(temp, 0o600)
        os.replace(temp, path)
        prune(directory, path)
    return str(path)


def prune(directory, keep):
    """Drop launch settings this profile has not resolved for a while; they are ~200 bytes."""
    cutoff = time.time() - 7 * 24 * 3600
    for stale in directory.glob("*.json"):
        if stale == keep:
            continue
        try:
            if stale.stat().st_mtime < cutoff:
                stale.unlink()
        except OSError:
            continue


def run(env):
    harness = env.get("AGENTS_HARNESS")
    if harness not in HARNESSES:
        raise Fail(f"AGENTS_HARNESS must be one of {', '.join(HARNESSES)}, not {harness!r}")
    profile = env.get("AGENTS_PROFILE")
    if not profile:
        raise Fail("AGENTS_PROFILE is not set")
    baseline_path = env.get("AGENTS_BASELINE")
    if not baseline_path:
        raise Fail("AGENTS_BASELINE is not set, so there is nothing to resolve")
    baseline = read_json(baseline_path)

    resolved = resolve(env)

    desired = {}
    for name, path in (resolved.get("skills") or {}).items():
        if path:
            desired[name] = path
    extras = env.get("AGENTS_SKILL_EXTRAS")
    if extras:
        for name, path in (read_json(extras) or {}).items():
            if isinstance(path, str) and path:
                desired[name] = path

    profile_dir = Path(profile)
    profile_dir.mkdir(parents=True, exist_ok=True)
    home = env.get("HOME") or str(Path.home())
    with open(profile_dir / LOCK, "w", encoding="utf-8") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        manifest_path = profile_dir / MANIFEST
        manifest = read_json(manifest_path) if manifest_path.exists() else {}
        if not isinstance(manifest, dict):
            manifest = {}
        rewritten = 0
        printed = None
        linked = 0
        if harness == "pi":
            # pi loads skill paths from settings, so there is no directory view to keep and
            # nothing shared for a launch to rewrite under a running session.
            rewritten = sync_pi_settings(profile_dir, resolved, baseline, manifest, home, desired)
        else:
            # Claude Code only discovers skills in its config dir, so this is a profile view.
            # A launch rewrites this shared view. Loaded instructions are not replaced, but
            # later file reads in an older session can observe another launch's skill view.
            previous = set(manifest.get("skills") or [])
            # Journal names before touching links: if refresh fails part-way through, a
            # later reset still knows which newly created entries it must remove.
            manifest["skills"] = sorted(previous | set(desired))
            write_json(manifest_path, manifest)
            roots = (STORE_ROOT, f"{env.get('AGENTS_CHECKOUT') or ''}/") if env.get("AGENTS_CHECKOUT") else (STORE_ROOT,)
            linked = sync_skills(profile_dir, desired, previous, roots)
            manifest["skills"] = sorted(desired)
            printed = claude_settings(env, resolved)
        write_json(manifest_path, manifest)
        fcntl.flock(lock, fcntl.LOCK_UN)

    if linked:
        say(f"{len(desired)} skills, {linked} changed")
    if rewritten:
        say("settings.json refreshed")
    if printed:
        print(printed)
    return 0


def main():
    try:
        return run(os.environ)
    except Fail as exc:
        say(str(exc))
        return 1


if __name__ == "__main__":
    sys.exit(main())
