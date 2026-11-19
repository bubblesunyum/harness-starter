// Drives the opencode session plugin's context hook with a fake session.
// Usage: bun|node scripts/test-opencode-session-plugin.mjs <plugin path> <project dir>
// Exits nonzero naming the failing assert; prints "plugin ok" on success.

import { chmodSync, mkdirSync, mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { pathToFileURL } from "node:url"

const [pluginPath, projectDir] = process.argv.slice(2)
if (!pluginPath || !projectDir) {
  console.error("usage: test-opencode-session-plugin.mjs <plugin path> <project dir>")
  process.exit(1)
}
const fail = (msg) => {
  console.error(`error: ${msg}`)
  process.exit(1)
}
// The gate itself may run inside a headless agent run, which sets the skip
// flag for every child — the driver below sets it per-assert instead.
delete process.env.HARNESS_AGENT_RUN

const mod = await import(pathToFileURL(pluginPath).href)
const plugin = mod.default
if (!plugin || typeof plugin.setup !== "function") fail("the plugin has no setup")
const contextHook = async (directory) => {
  let hook = null
  await plugin.setup({
    location: { directory },
    session: { hook: async (name, fn) => { if (name === "context") hook = fn } },
  })
  if (typeof hook !== "function") fail(`the plugin registered no context hook for ${directory}`)
  return hook
}

// The brief reaches the system prompt of a fresh session.
const hook = await contextHook(projectDir)
const first = { sessionID: "ses_probe", system: [] }
await hook(first)
const text = first.system.map((p) => p.text).join("\n")
if (!text.includes("Working on this project")) fail("the brief never reached the system prompt")

// A successful brief is cached per session.
const second = { sessionID: "ses_probe", system: [] }
await hook(second)
if (second.system.length !== 1 || second.system[0].text !== text) fail("the brief is not cached per session")

// Headless agent runs already carry the brief, so the hook stays silent.
process.env.HARNESS_AGENT_RUN = "1"
const skipped = { sessionID: "ses_probe", system: [] }
await hook(skipped)
if (skipped.system.length !== 0) fail("a headless agent run injected the brief")
delete process.env.HARNESS_AGENT_RUN

// A failing harness is one loud line, never a broken session.
const badHook = await contextHook("/nonexistent-probe-project")
const bad = { sessionID: "ses_probe", system: [] }
await badHook(bad)
if (bad.system.length !== 1 || !bad.system[0].text.includes("session brief failed")) {
  fail("a failing harness was not one loud line")
}

// A failure is never cached: fix the harness and the same session retries
// into the brief instead of replaying the loud line.
const retryDir = mkdtempSync(join(tmpdir(), "probe-opencode-plugin-"))
mkdirSync(join(retryDir, "scripts"), { recursive: true })
const retryHarness = join(retryDir, "scripts", "harness")
writeFileSync(retryHarness, '#!/bin/bash\necho "probe-harness-broke" >&2\nexit 1\n')
chmodSync(retryHarness, 0o755)
const retryHook = await contextHook(retryDir)
const failed = { sessionID: "ses_retry", system: [] }
await retryHook(failed)
if (failed.system.length !== 1 || !failed.system[0].text.includes("session brief failed")) {
  fail("a failing harness was not one loud line")
}
if (!failed.system[0].text.includes("exit 1: probe-harness-broke")) {
  fail("the loud line never said what went wrong")
}
writeFileSync(retryHarness, '#!/bin/bash\necho "Working on this project retry-brief"\n')
const retried = { sessionID: "ses_retry", system: [] }
await retryHook(retried)
if (retried.system.length !== 1 || !retried.system[0].text.includes("Working on this project")) {
  fail("a fixed harness never healed the session — the failure was cached")
}

console.log("plugin ok")
