import contextlib
import importlib.util
import io
from pathlib import Path
import sys
import tomllib
import unittest
from unittest.mock import patch


SUITE = Path(__file__).resolve().parents[1] / "eval-docs"


def module(name):
    spec = importlib.util.spec_from_file_location(name, SUITE / f"{name}.py")
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


compare = module("compare")
review = module("review")


class ContextComparisonTest(unittest.TestCase):
    def test_one_variable_per_comparison(self):
        cases = tomllib.loads((SUITE / "cases.toml").read_text())
        for name, case in cases.items():
            if "neighbors" not in case:
                continue
            with self.subTest(case=name):
                clear = compare.with_neighbor(case["task"], case["neighbors"]["clear"])
                dense = compare.with_neighbor(case["task"], case["neighbors"]["dense"])
                self.assertNotEqual(clear, dense)
                _, pair = compare.variants(case, "current", None, True, None)
                self.assertEqual(pair, [("clear context", "current", clear), ("dense context", "current", dense)])
                for style, task in (("clear", clear), ("dense", dense)):
                    _, pair = compare.variants(case, "new", "old", False, style)
                    self.assertEqual(pair, [("baseline", "old", task), ("candidate", "new", task)])

    def test_blind_report_round_trip(self):
        def fake_model(command, *, input, **kwargs):
            return compare.subprocess.CompletedProcess(command, 0, input.split("\n")[-1])

        output = io.StringIO()
        argv = ["compare.py", "fixture/model", "--compare-style", "--case", "trace-legend"]
        with patch.object(sys, "argv", argv), patch.object(compare.subprocess, "run", fake_model):
            with contextlib.redirect_stdout(output), contextlib.redirect_stderr(io.StringIO()):
                compare.main()
        with patch.object(review, "render", str.strip):
            run = review.load_run(output.getvalue())
        case = run["cases"][0]
        self.assertNotIn("dense context", case["task"])
        self.assertNotIn("clear context", case["task"])
        self.assertEqual(set(case["versions"]), {"clear context", "dense context"})
        self.assertEqual(len(case["answers"]), 2)
        neighbors = tomllib.loads((SUITE / "cases.toml").read_text())["trace-legend"]["neighbors"]
        for answer, version in zip(case["answers"], case["versions"]):
            self.assertEqual(answer, neighbors[version.removesuffix(" context")].splitlines()[-1])
