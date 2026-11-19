// Runs `scripts/harness session` once per opencode session and adds the brief
// to the system prompt, so every session starts with the harness contract and
// the seat's brief without anyone remembering to run it. Plain JS on purpose:
// opencode discovers this file under .opencode/plugins/ and the default export
// is all it needs — no Plugin import, no package, nothing to install.
//
// The brief is cached per session: the first context hook call in a session
// shells out (20s cap, project root as cwd) and every later call reuses a
// successful brief. A failure is never cached — the next call retries, so
// fixing the harness heals the session without a restart. A failing harness
// never throws — it leaves one loud line naming the fix.
// Headless harness agent runs (HARNESS_AGENT_RUN=1, set by
// scripts/harness agent) skip this entirely: the caller already carries the
// brief in the prompt, and every injected line would bill it twice.

import { spawnSync } from "node:child_process"

const LOAD_TIMEOUT_MS = 20000
const SKIP_ENV = "HARNESS_AGENT_RUN"
const FAIL_PREFIX = "\u2717 harness: session brief failed"

function failLine(reason) {
  return `${FAIL_PREFIX} (${reason}) \u2014 run scripts/harness session yourself`
}

// The first thing the harness said on stderr: a bare exit code sends the
// next reader to rerun by hand to see the error, so the loud line carries it.
function firstStderrLine(stderr) {
  const line = (stderr || "").split("\n").map((s) => s.trim()).find((s) => s.length > 0) || ""
  return line.slice(0, 200)
}

function loadBrief(projectRoot) {
  // One loud line, never a throw: whatever is wrong — no finder, a hung
  // harness — the session still starts, and the line says the fix.
  if (!projectRoot) return failLine("no project directory")
  let out
  try {
    out = spawnSync("scripts/harness", ["session"], {
      cwd: projectRoot,
      timeout: LOAD_TIMEOUT_MS,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    })
  } catch (err) {
    return failLine(err && err.message ? err.message : String(err))
  }
  if (out.error) {
    const timedOut = out.error.code === "ETIMEDOUT"
    return failLine(timedOut ? `timed out after ${LOAD_TIMEOUT_MS / 1000}s` : (out.error.message || String(out.error)))
  }
  if (out.status !== 0) {
    const errLine = firstStderrLine(out.stderr)
    return failLine(errLine ? `exit ${out.status}: ${errLine}` : `exit ${out.status}`)
  }
  const text = (out.stdout || "").trim()
  if (!text) return failLine("empty output")
  return text
}

export default {
  id: "harness-session",
  async setup(ctx) {
    const projectRoot = ctx && ctx.location && ctx.location.directory
    const briefBySession = new Map()
    const briefFor = (sessionID) => {
      const key = sessionID || ""
      if (briefBySession.has(key)) return briefBySession.get(key)
      const text = loadBrief(projectRoot)
      if (!text.startsWith(FAIL_PREFIX)) briefBySession.set(key, text)
      return text
    }
    await ctx.session.hook("context", (event) => {
      // Headless harness runs already carry the brief in their own prompt.
      if (process.env[SKIP_ENV] === "1") return
      if (!event || !Array.isArray(event.system)) return
      let text
      try {
        text = briefFor(event.sessionID)
      } catch (err) {
        text = failLine(err && err.message ? err.message : String(err))
      }
      try {
        event.system.push({ type: "text", text })
      } catch {
        // The hook must never break the model call it decorates.
      }
    })
  },
}
