@AGENTS.md

# CLAUDE.md

harness-starter is the agentic development harness itself, packaged so it can be
installed into any project. `template/` is the product AND what the starter
runs: the root carries a reference install whose finder resolves this
checkout's own `template/` first, so there are no root copies and nothing to
carry across.

**Every real change goes in `template/`.** It is live everywhere at once —
the starter runs it directly, every project on its next command. See "Working
on the starter" in README.md.

## Taste

Shell and Python read by someone at 2am when something has broken: the usage
comment at the top and the error message on the way out are part of the
interface, not decoration. Small single-purpose functions. Comments explain a
*why* — a workaround, a platform gotcha — never what the line below already says.
Names read as documentation.

A starter is judged on what it does when its assumptions are wrong: a bad path,
a half-initialised ledger, a name with no usable characters, a symlink pointing
somewhere surprising. Failing loudly beats failing silently every time, and
silent success on a broken install is the worst outcome available.
