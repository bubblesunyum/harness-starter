#!/usr/bin/env python3
"""The project and the shared harness checkout, resolved in one place.

Every shared script answers the same two questions: which checkout is the
project (ROOT), and which checkout was this script loaded from (HARNESS).
Dispatched runs export both as $HARNESS_PROJECT / $HARNESS_ROOT; anywhere
else each side falls back to the dir passed in, or to this module's own
checkout — the same dir an installed copy resolves to. One module so the
env contract and the project-first shadow rule can't drift apart again:
a second copy of either is how a project file silently replaced the gate's
own probe.
"""

import os
from pathlib import Path


def resolve(project=None, harness=None, env=True):
    """The (ROOT, HARNESS, harness_script) triple for explicit fallbacks.

    $HARNESS_PROJECT / $HARNESS_ROOT win when set. Each side otherwise
    falls back to the dir passed for it, or to this module's own checkout.
    dashboard.py passes its git-probed project root and its own dir;
    brief.sh's embedded probe passes the roots it was given on argv.
    env=False ignores both variables: a dashboard switching checkouts must
    land on the root it was handed, not the one it was dispatched for.
    """
    own = Path(__file__).resolve().parent.parent
    environ = os.environ if env else {}
    root = Path(environ.get("HARNESS_PROJECT") or project or own)
    shared = Path(environ.get("HARNESS_ROOT") or harness or own)

    def harness_script(name):
        """A sibling script: the project's copy when it shadows this file,
        else the harness copy. Never a bare scripts/<f>, which only resolves
        when the copy lives in the project."""
        cand = root / "scripts" / name
        return cand if cand.exists() else shared / "scripts" / name

    return root, shared, harness_script


ROOT, HARNESS, harness_script = resolve()
