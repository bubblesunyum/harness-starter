@AGENTS.md

# CLAUDE.md

harness-starter is the agentic development harness itself, packaged so it can be
installed into any project. `template/` is the product; the root is a working
install of it, put there by `harness add`.

**Every real change goes in `template/`.** The root `scripts/` are substituted
copies made at install time — editing one does not change the other, and the
running harness here is the copy. See "Working on the starter" in README.md.

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
