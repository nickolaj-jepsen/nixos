import argparse
import hashlib
import random
import re
import subprocess
import sys
import tempfile
import tomllib
from pathlib import Path


HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
CONTEXT = "modules/programs/agent-context.md"


def git(*args):
    return subprocess.check_output(["git", *args], cwd=REPO, text=True).strip()


def documentation(text):
    section = re.search(r"^## Documentation\n(.*?)(?=^## |\Z)", text, re.MULTILINE | re.DOTALL)
    return section[1].strip() if section else ""


def baseline_for(args, candidate, parser):
    if args.base_file:
        baseline = args.base_file.read_text().strip()
        revision = hashlib.sha256(baseline.encode()).hexdigest()[:12]
    else:
        base = args.base or "HEAD"
        baseline = documentation(git("show", f"{base}:{CONTEXT}"))
        if baseline == candidate and args.base is None:
            for revision in git("log", "--format=%H", "--", CONTEXT).splitlines():
                previous = documentation(git("show", f"{revision}:{CONTEXT}"))
                if previous != candidate:
                    base, baseline = revision, previous
                    break
        revision = git("rev-parse", "--short", base)
    if baseline == candidate:
        parser.error("the two prompts are identical; choose an earlier --base")
    return revision, baseline


def with_neighbor(task, excerpt):
    return f"{task.strip()}\n\nAdjacent section of the same guide:\n\n{excerpt.strip()}"


def variants(case, candidate, baseline, compare_style, neighbor_style):
    task = case["task"]
    if compare_style:
        neighbors = case["neighbors"]
        shared = task.strip() + "\n\nEach answer saw one of these adjacent excerpts."
        for i, style in enumerate(("clear", "dense"), 1):
            shared += f"\n\nExcerpt {i}:\n{neighbors[style].strip()}"
        return shared, [(style + " context", candidate, with_neighbor(task, neighbors[style]))
                        for style in ("clear", "dense")]
    if "neighbors" in case:
        task = with_neighbor(task, case["neighbors"][neighbor_style or "clear"])
    return task, [("baseline", baseline, task), ("candidate", candidate, task)]


def main():
    cases = tomllib.loads((HERE / "cases.toml").read_text())
    parser = argparse.ArgumentParser(
        description="Compare two versions of the documentation guidance or test the effect of adjacent prose. Save stdout for review."
    )
    parser.add_argument("model", nargs="?", help="pi provider/model ID; omit for an offline preview")
    parser.add_argument("--case", choices=cases, action="append", help="run only this case (repeatable)")
    base_options = parser.add_mutually_exclusive_group()
    base_options.add_argument("--base", help="Git revision to compare with the working copy")
    base_options.add_argument("--base-file", type=Path, help="saved documentation passage from an earlier run")
    parser.add_argument("--provider-extension", type=Path, help="load this pi model provider with extension discovery disabled")
    base_options.add_argument("--compare-style", action="store_true",
                              help="hold guidance fixed and vary the adjacent page; defaults to all matched cases")
    parser.add_argument("--neighbor-style", choices=("clear", "dense"),
                        help="compare guidance on matched cases with the same adjacent style in both runs")
    args = parser.parse_args()
    if args.compare_style and args.neighbor_style:
        parser.error("--compare-style varies the adjacent style; --neighbor-style holds it fixed")

    candidate = documentation((REPO / CONTEXT).read_text())
    if not candidate:
        parser.error(f"missing Documentation section in {CONTEXT}")
    matched_only = args.compare_style or args.neighbor_style is not None
    selected = args.case or [name for name, case in cases.items() if not matched_only or "neighbors" in case]
    if matched_only:
        for name in selected:
            if "neighbors" not in cases[name]:
                parser.error(f"{name} has no matched neighboring passages")
    if args.compare_style:
        baseline = None
    else:
        base_commit, baseline = baseline_for(args, candidate, parser)
    digest = hashlib.sha256(candidate.encode()).hexdigest()[:12]
    if args.compare_style:
        header = f"Model `{args.model}` · guidance `{digest}` · compare adjacent style"
    else:
        header = f"Model `{args.model}` · baseline `{base_commit}` · candidate `{digest}`"
    system_prompt = "Answer this self-contained editing exercise in chat. The supplied text is the entire input."
    common = "There are no files to inspect or edit and no tools are available. Reply directly with the requested text."
    if not args.model:
        print(f"System prompt (both runs):\n{system_prompt}\n\nAdditional instructions (both runs):\n{common}")
        if baseline is not None:
            print(f"\nBaseline addition ({base_commit}):\n{baseline or '(none)'}")
        print(f"\nCandidate addition ({digest}):\n{candidate}")
        for name in selected:
            shared, _ = variants(cases[name], candidate, baseline, args.compare_style, args.neighbor_style)
            print(f"\n## {name}\n\n{shared.strip()}")
        return

    print(f"# Documentation review\n\n{header}")
    with tempfile.TemporaryDirectory() as scratch:
        for name in selected:
            case = cases[name]
            shared, pair = variants(case, candidate, baseline, args.compare_style, args.neighbor_style)
            print(f"\n## {name}\n\n{shared.strip()}\n", flush=True)
            random.SystemRandom().shuffle(pair)
            for label, (_, prompt, task) in zip("AB", pair):
                print(f"Running {name} {label}", file=sys.stderr)
                command = [
                    "pi", "--print", "--no-session", "--no-tools", "--no-extensions",
                    "--no-skills", "--no-context-files", "--no-prompt-templates",
                    "--model", args.model, "--system-prompt", system_prompt,
                    "--append-system-prompt", (common + "\n\n" + prompt).strip(),
                ]
                if args.provider_extension:
                    command.extend(["--extension", str(args.provider_extension.resolve())])
                result = subprocess.run(
                    command, cwd=scratch, input=task, text=True, stdout=subprocess.PIPE, check=True
                )
                if not result.stdout.strip():
                    raise SystemExit(f"Empty response for {name} {label}")
                print(f"### {label}\n\n{result.stdout.strip()}\n", flush=True)
            print(f"**Review.** {case['review']}\n\nPick A, B, both or neither. Which passage decided it?\n")
            print(f"<details><summary>Reveal versions</summary>\n\nA = {pair[0][0]}, B = {pair[1][0]}\n\n</details>")


if __name__ == "__main__":
    main()
