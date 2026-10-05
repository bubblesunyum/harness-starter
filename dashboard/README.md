# Harness dashboard

The dashboard is a local view of a project's beads, Git worktree, gate, review,
and session state. It serves on loopback, starts in the background by default,
and refreshes its snapshot while the page is open.

## Files

- `scripts/dashboard.py` serves the board and implements `up`, `down`, `serve`,
  `snapshot`, and `shot`.
- `scripts/dashboard-persist.sh` starts a board that survives session-end hooks
  and idle shutdown.
- `dashboard/index.html` is the page; `dashboard/vendor/` contains its bundled
  browser libraries and their licenses.
- `dashboard.toml` defines the project's display name, run buttons, and
  optional gate verdict pattern.
- `dashboard/state.json` is generated runtime state. It is refreshed by the
  server and is not a template asset.

## Requirements

The dashboard files can be copied as a unit into a compatible Git project that
uses Beads. It finds the project root through Git and reads the ledger with
`bd`. Python 3.11 or newer, `git`, and `bd` on `PATH` are required. Chrome is
needed only for screenshot capture; the capture command currently looks for
Google Chrome at `/Applications/Google Chrome.app/Contents/MacOS/Google Chrome`.

## Run it

From the project root, start the background server and open the printed local
URL in the project's browser pane:

```bash
python3 scripts/dashboard.py
```

The default command is `up`; it chooses an available port starting at 7391.
Use `python3 scripts/dashboard.py up --port 7391` to request a specific port.
Run `python3 scripts/dashboard.py serve` to keep the server in the foreground
and stop it with Ctrl-C.

Stop a board started for the current session with:

```bash
python3 scripts/dashboard.py down
```

To keep it running across session-end hooks and idle shutdown, use
`scripts/dashboard-persist.sh`. Stop that persistent board with
`python3 scripts/dashboard.py down --force`.

Write the current snapshot without starting a server with:

```bash
python3 scripts/dashboard.py snapshot
```

Capture a screenshot from a running board with Chrome:

```bash
mkdir -p .tmp
python3 scripts/dashboard.py shot .tmp/dashboard.png gate peers
```

The supported states are `gate`, `pulse`, `review`, `staging`, `commit`,
`filemenu`, and `peers`. With no path, screenshots go to a generated file under
`/tmp`; with named states, one image per state is written beside the chosen
path. The board lists detected dashboard peers; choose one to switch the current
server to that checkout.

## Configure it

`dashboard.toml` is optional: without it, the board uses its standard run and
push actions and names itself after the project directory. Edit it to set
`[project].name` or add `[[task]]` entries. Each
task has a unique name, an argument-list `command`, short `label` and `busy`
text, and a `where` location (`header`, `gate`, or `lane:<key>`). Commands run
from the project root. The page reloads this file as it builds snapshots, so
configuration changes take effect without restarting the server.

An optional `[verdict].pattern` is a regular expression with exactly one
capturing group for the verdict word. If the gate has no verdict pattern, the
dashboard falls back to its error-line check.

## Restyle it

Three optional `dashboard.toml` tables restyle the page without forking
shipped files. Each is read independently: one bad table keeps its last good
values and complains on the server's stderr, while the good ones keep
updating. `state.json` carries all three as `theme`, `board`, and `assets`.

An optional `[theme]` table maps a CSS variable name to its value, applied as
an inline custom property:

```toml
[theme]
"--accent" = "#6a5acd"
```

Names look like `--lowercase-letters-and-dashes` (max 40 characters); values
are at most 200 characters and must not hold markup (`</`) or `url(...)`,
which never render.

An optional `[board]` table hides and reorders the page's own sections:

```toml
[board]
hidden = ["peers"]
order = ["ready", "in_progress", "done"]
```

`hidden` lists sections to hide; `order` lists sections front to back, and
sections it doesn't name keep their usual place after the ordered ones.
Valid keys are the sections the page renders: `ready`, `blocked`,
`in_progress`, `review`, `staging`, `worktree`, `done`, `backlog`, `harness`,
`budget`, `gate`, `peers`. Anything else is rejected loudly.

An optional `[assets]` table lists project-owned files served beside the
page:

```toml
[assets]
css = ["dashboard-assets/brand.css"]
js = ["dashboard-assets/extra.js"]
```

Every entry is a project-relative path that must sit under `dashboard-assets/`,
a top-level directory the dashboard updater never scans, so custom files
survive updates. `css` entries end in `.css`, `js` entries in `.js`; no
absolute paths, no `..` escapes. The state lists them stripped to the path
inside that directory (`{"css": ["brand.css"]}`), fetched at
`/assets/brand.css` as `text/css` or `text/javascript`. Files over 200KB and
paths the table never listed answer 404. Assets are static bytes only and are
never executed server-side.

The installer creates `dashboard.toml` once and later dashboard updates leave
it project-owned. To refresh the page and dashboard server from the starter, run:

```bash
harness update dashboard
```

That command re-copies `dashboard/` and `scripts/dashboard.py`, preserves the
generated `dashboard/state.json`, and leaves `dashboard.toml` alone. After a
successful update those shipped page and server files match the starter byte
for byte. The regular harness update path handles other contract files,
including `scripts/dashboard-persist.sh`.
