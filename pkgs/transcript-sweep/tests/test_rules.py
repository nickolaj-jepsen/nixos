#!/usr/bin/env python3
"""What each rule matches, and what it must leave alone.

Run with `PYTHONPATH=pkgs/transcript-sweep python3 pkgs/transcript-sweep/tests/test_rules.py`,
or through `nix build .#transcript-sweep`.
"""

from __future__ import annotations

import unittest

from transcript_sweep.rules import fingerprint, redact_text

PEM = (
    "-----BEGIN OPENSSH PRIVATE KEY-----\r\n"
    "b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW\r\n"
    "QyNTUxOQAAACB0aGluZ3MgdGhhdCBhcmUgbm90IGEga2V5IGF0IGFsbCBoZXJlAA==\r\n"
    "-----END OPENSSH PRIVATE KEY-----"
)


def redact(text: str, **kwargs: object) -> tuple[str, dict[str, int]]:
    return redact_text(text, **kwargs)  # type: ignore[arg-type]


class PrivateKeys(unittest.TestCase):
    def test_complete_block_is_gone_including_body(self) -> None:
        new, hits = redact(f"before {PEM} after")
        self.assertEqual(hits, {"private-key": 1})
        self.assertTrue(new.startswith("before [redacted:private-key:"))
        self.assertTrue(new.endswith("] after"))
        self.assertNotIn("b3BlbnNzaC1rZXk", new)

    def test_truncated_key_keeps_the_rest_of_the_entry(self) -> None:
        text = "-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEA1234abcd\nMIIEowIBAAKCAQEA5678efgh\ntrailing prose"
        new, hits = redact(text)
        self.assertEqual(hits, {"private-key": 1})
        self.assertTrue(new.endswith("trailing prose"))
        self.assertNotIn("MIIEowIBAAKCAQEA", new)

    def test_pgp_block(self) -> None:
        text = "-----BEGIN PGP PRIVATE KEY BLOCK-----\n\nlQOYBF\n-----END PGP PRIVATE KEY BLOCK-----"
        new, hits = redact(text)
        self.assertEqual(hits, {"private-key": 1})
        self.assertNotIn("lQOYBF", new)

    def test_certificate_is_not_a_secret(self) -> None:
        text = "-----BEGIN CERTIFICATE-----\nMIIC\n-----END CERTIFICATE-----"
        self.assertEqual(redact(text), (text, {}))


class Tokens(unittest.TestCase):
    def test_github_token(self) -> None:
        token = "ghp_" + "a1B2" * 9
        new, hits = redact(f"GITHUB_TOKEN={token}")
        self.assertEqual(hits, {"github-token": 1})
        self.assertEqual(new, f"GITHUB_TOKEN=[redacted:github-token:{fingerprint(token)}]")

    def test_github_placeholder_is_left_alone(self) -> None:
        text = "GITHUB_TOKEN=ghp_PLACEHOLDER"
        self.assertEqual(redact(text), (text, {}))

    def test_age_key_needs_its_body(self) -> None:
        body = "A" * 30 + "B" * 28
        key = f"AGE-SECRET-KEY-1{body}"
        new, hits = redact(f"export SOPS_AGE_KEY='{key}'")
        self.assertEqual(hits, {"age-key": 1})
        self.assertIn("SOPS_AGE_KEY='[redacted:age-key:", new)

    def test_bare_age_prefix_is_prose(self) -> None:
        text = "the AGE-SECRET-KEY-1 prefix, then 58 characters"
        self.assertEqual(redact(text), (text, {}))

    def test_aws_key_id_inside_a_blob_is_not_a_key(self) -> None:
        # Base64 filler in these logs can read as AKIA…; both sides anchor it out.
        text = "iVBORw0KGgoAKIAIOSFODNN7EXAMPLEAAAAB"
        self.assertEqual(redact(text), (text, {}))

    def test_standalone_aws_key_id(self) -> None:
        new, hits = redact("key id AKIAIOSFODNN7EXAMPLE here")
        self.assertEqual(hits, {"aws-key-id": 1})
        self.assertNotIn("AKIAIOSFODNN7EXAMPLE", new)

    def test_aws_secret_keeps_the_name(self) -> None:
        new, hits = redact("aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
        self.assertEqual(hits, {"aws-secret": 1})
        self.assertTrue(new.startswith("aws_secret_access_key = [redacted:aws-secret:"))
        self.assertNotIn("wJalrXUtnFEMI", new)

    def test_jwt_needs_two_json_segments(self) -> None:
        token = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        new, hits = redact(f"Authorization: Bearer {token}")
        self.assertEqual(hits, {"jwt": 1})
        self.assertNotIn("dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1gFWFOEjXk", new)

    def test_prose_that_starts_like_a_jwt(self) -> None:
        text = "the eyJhbGciOiJIUzI1NiJ9 header alone"
        self.assertEqual(redact(text), (text, {}))


class Idempotence(unittest.TestCase):
    def test_second_pass_changes_nothing(self) -> None:
        text = f"{PEM}\nghp_{'a1B2' * 9}\naws_secret_access_key = {'z' * 40}"
        once, hits = redact(text)
        twice, again = redact(once)
        self.assertTrue(hits)
        self.assertEqual(once, twice)
        self.assertEqual(again, {})

    def test_fingerprint_correlates_occurrences(self) -> None:
        token = "ghp_" + "a1B2" * 9
        new, _ = redact(f"{token} and {token}")
        self.assertEqual(len(set(new.split(" and "))), 1)


class Literals(unittest.TestCase):
    def test_value_from_a_file(self) -> None:
        literals = {"hunter2-correct": "value"}
        new, hits = redact("password is hunter2-correct", literals=literals)
        self.assertEqual(hits, {"value": 1})
        self.assertNotIn("hunter2", new)

    def test_short_values_are_ignored(self) -> None:
        text = "a b c"
        self.assertEqual(redact(text, literals={"a b": "value"}), (text, {}))

    def test_absent_value_is_not_a_hit(self) -> None:
        self.assertEqual(redact("nothing here", literals={"elsewhere": "value"}), ("nothing here", {}))


class Reporting(unittest.TestCase):
    def test_samples_are_placeholders_not_values(self) -> None:
        token = "ghp_" + "a1B2" * 9
        samples: dict[str, str] = {}
        redact(f"{token} {token}", samples=samples)
        self.assertEqual(samples, {"github-token": f"[redacted:github-token:{fingerprint(token)}]"})
        self.assertNotIn(token, samples["github-token"])

    def test_hits_count_every_occurrence(self) -> None:
        token = "ghp_" + "a1B2" * 9
        _, hits = redact(f"{token} {token} {token}")
        self.assertEqual(hits, {"github-token": 3})


if __name__ == "__main__":
    unittest.main()
