#!/usr/bin/env python3
"""Pin the scratch rule's teeth in opencode.json (har-my2).

    python3 scripts/test-opencode-permissions.py

AGENTS.md prose tells agents to scratch in ./.tmp/, but prose is advisory.
What blocks `>`-redirect temp writes is this config: `edit` denies the file
tools in temp dirs, and granular `bash` rules deny shell redirects naming
temp dirs while the catch-all stays allow so packet reads via cat keep
working. `$TMPDIR` (macOS /var/folders/..., realpath /private/var/...)
matches neither /tmp/* nor /private/tmp/*, so it gets its own rules in both
the expanded and the unexpanded spelling — agents type the bare var, often
quoted or braced, hence `*>*TMPDIR*` rather than an exact `> $TMPDIR/`.

Deliberately uncovered: non-redirect write vectors (tee/cp/mkdir/mktemp,
-o flags, python one-liners, $VAR indirection) — command-string wildcards
cannot close those without breaking legit flows like `bd export -o`, so
AGENTS.md prose remains the control there.
"""

import json
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
REPO = SCRIPTS.parent

EDIT_DENY = ("/tmp/*", "/private/tmp/*", "/var/folders/*", "/private/var/folders/*")
BASH_DENY = ("*>*/tmp/*", "*>*/private/tmp/*", "*>*/var/folders/*",
             "*>*/private/var/folders/*", "*>*TMPDIR*")


def configs():
    paths = [REPO / "opencode.json", REPO / "template" / "opencode.json"]
    return [p for p in paths if p.is_file()]


class TestOpencodePermissions(unittest.TestCase):
    def test_configs_present_and_parse(self):
        found = configs()
        self.assertTrue(found, "no opencode.json found")
        for path in found:
            with self.subTest(path=str(path)):
                json.load(path.open())

    def test_edit_denies_temp_writes(self):
        for path in configs():
            with self.subTest(path=str(path)):
                edit = json.load(path.open())["permission"]["edit"]
                for pattern in EDIT_DENY:
                    self.assertEqual(edit.get(pattern), "deny", pattern)

    def test_bash_denies_temp_redirects_keeps_catchall_allow(self):
        for path in configs():
            with self.subTest(path=str(path)):
                bash = json.load(path.open())["permission"]["bash"]
                self.assertEqual(bash.get("*"), "allow")
                denied = [k for k, v in bash.items() if v == "deny"]
                for pattern in BASH_DENY:
                    self.assertIn(pattern, denied, pattern)
                # The catch-all allow must come first: opencode applies the
                # last matching rule, so a leading "*" keeps reads working
                # and the redirect denies after it win on writes.
                keys = list(bash)
                self.assertLess(keys.index("*"),
                                min(keys.index(p) for p in BASH_DENY))


if __name__ == "__main__":
    unittest.main()
