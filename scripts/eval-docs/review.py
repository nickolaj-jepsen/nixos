"""Build a standalone scorecard from a completed compare.py report."""

import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path


def render(markdown):
    return subprocess.check_output(
        ["cmark-gfm", "--extension", "table"], input=markdown, text=True
    )


def load_run(source):
    header, *sections = source.strip().split("\n</details>")
    model = re.search(r"^Model `([^`]+)` · baseline `([^`]+)` · candidate `([^`]+)`$", header, re.M)
    names = ("model", "baseline", "candidate")
    keys = ("baseline", "candidate")
    if not model:
        model = re.search(r"^Model `([^`]+)` · guidance `([^`]+)` · compare adjacent style$", header, re.M)
        names = ("model", "guidance")
        keys = ("clear context", "dense context")
    if not model or not sections or sections[-1].strip():
        raise ValueError("Expected a completed documentation eval with a version key for every pair.")
    run = dict(zip(names, model.groups()))
    cases = []
    for section in [header[model.end():], *sections[:-1]]:
        title, task_and_answers = section.strip().split("\n", 1)
        if not title.startswith("## "):
            raise ValueError(f"Expected a case heading, got {title!r}")
        task, answers = task_and_answers.split("\n### A\n", 1)
        answers, rubric = answers.rsplit("\n**Review.** ", 1)
        a, b = answers.split("\n### B\n", 1)
        rubric, key = rubric.rsplit("\n\nPick A, B, both or neither.", 1)
        mapping = re.search(r"\nA = ([^,\n]+), B = ([^\n]+?)\s*$", key)
        if not mapping or set(mapping.groups()) != set(keys):
            raise ValueError(f"Invalid version key for {title}")
        cases.append(dict(name=title[3:], task=task.strip(), rubric=rubric.strip(),
                          answers=[render(a), render(b)], versions=mapping.groups()))
    run["cases"] = cases
    run["id"] = hashlib.sha256(source.encode()).hexdigest()[:16]
    return run


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=Path)
    args = parser.parse_args()
    source = args.report.read_text()
    run = load_run(source)
    template = Path(__file__).with_name("review.html").read_text()
    data = json.dumps(run, ensure_ascii=False).replace("<", "\\u003c")
    output = args.report.with_suffix(".html")
    if output == args.report:
        parser.error("Input must be a Markdown report")
    output.write_text(template.replace("__RUN_JSON__", data))
    print(output.resolve())


if __name__ == "__main__":
    main()
