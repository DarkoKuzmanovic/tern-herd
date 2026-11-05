# Headless screenshots of the Herd plugin

`test/shoot.sh` renders `plugins/herd` against **fixed, fake `hc` data** in a
throwaway `tern serve` and writes PNGs to `test/shots/`. It is the way to look
at the plugin's UI without a live herd, a live Tern window or a real
herdr-core, and the way to diff a redesign against the same fixtures.

Needs: `bash`, `jq`, GNU `find`/`touch`/`stat`, `tern` on `PATH` (0.9.12
or newer; `TERN=/path/to/tern` overrides), and a `hc`-shaped fixture — the real
herdr-core is never started.

## Run

```sh
cd ~/code/tern-herd
./test/shoot.sh demo empty error deep transitions        # 5 PNGs
./test/shoot.sh --size 700x900 demo                      # narrow (700 CSS px)
./test/shoot.sh --keys "l" demo                          # a key first: the read card
./test/shoot.sh --keys "j j l" demo                      # a row further down (no read fixture -> error card)
./test/shoot.sh --keys "sleep:7000" transitions             # later `ls` answers from seq/ (real time)
./test/shoot.sh --keys "Enter sleep:1500" demo           # watch split: the fake attach banner
./test/shoot.sh --keys "dblclick:.sf-tbl-row.sel" activation
./test/actions.sh                                      # actions, viewers, scopes, needs-you, activity, artifacts and opener guard
```

| option | meaning |
| --- | --- |
| `--size WxH` | viewport in CSS px (`resize W H`), e.g. `700x900`. Default: the serve's own, 1280x800 |
| `--keys "TOKEN …"` | `tern ctl key` tokens, `dblclick:CSS` selectors, or pause tokens `wait:MS` / `sleep:MS` (below); selectors cannot contain spaces |
| `SHOOT_KEEP=1` | keep the run's temp dir and leave the serve running (it prints the control socket); stop it yourself |
| `SHOOT_HOOK='…'` | run a strict shell snippet after the fake-hc assertion, with `$TEST`, `$T` (temp dir), `$SOCK` (control socket), `$TERNFD` (the `tern` binary), `$KVFILE` (the already validated private plugin-storage file) and `$SERVE_PID` set; artifact runs also provide `$ARTIFACT_HOME`, `$ARTIFACT_ROOT`, `$ARTIFACT_MISSING` (empty otherwise); failure fails the run |
| `SHOOT_PLUGIN_DIR=DIR` | test a private plugin working copy instead of the linked source |
| `SHOOT_CONTENDER=1` | load a second independent copy of the production window VM against the same host requests |
| `SHOOT_NO_CONSUMER=1` | load a bootstrap-only window half; no action consumer, for expiry and manual claim tests |
| `SHOOT_WORKTREE=1` | replace fixture cwd values in the temporary copy with a new private git repository for `w` |
| `SHOOT_PHASED=1` | copy the fixture privately before starting Tern, park `seq/` as `phases/`, and hold phase 01 until a hook atomically promotes another snapshot; never edits repository fixtures |
| `SHOOT_ARTIFACTS=1` | copy `artifacts` fixture/files under `$T/home/alex`, use real private checkout cwd values and an artifact-only serve `HOME`/`XDG_CONFIG_HOME`, set review mtimes deterministically, and log genuine GNU `find` calls; repository fixtures and other scenarios' environments are unchanged |

### `sleep:MS` vs `wait:MS`

The block polls `hc ls` from a **host timer on real time** (every 2 s). The two
tokens pause differently, and only one of them lets that poll happen:

| token | what it does | use it for |
| --- | --- | --- |
| `sleep:7000` | really sleeps 7 s in the harness, then the settle loop waits for what got painted | anything that depends on the host's own timers: a `seq/` fixture advancing (`transitions`), a notice expiring, the "finished hidden" count moving |
| `wait:3000` | `tern ctl wait 3000`: advances the serve's **simulated app clock**, including window request polling | Window-side timers and animations. It does **not** fire the block's real-time 2 s poll, so `hc.log` gains no `ls` calls |

Proof of the difference, `transitions` (4 `seq/` answers):

```sh
./test/shoot.sh --keys "sleep:7000" transitions   # hc.log: 6 `ls --json` calls, PNG shows seq/04 (Working 0, Done 4)
./test/shoot.sh --keys "wait:7000" transitions    # hc.log: 1 `ls --json` call, PNG still shows seq/01 (Working 4)
```

`<scenario>` is a directory name under `test/fixtures/`. One PNG per scenario
per invocation; run it once per option set.

## What lands in `test/shots/`

For each scenario (suffix = `-WxH` when `--size`, `-k-<keys>` when `--keys`,
with spaces and colons as `_`/`-`):

| file | what |
| --- | --- |
| `<name>.png` | the shot: the whole window, device scale 2, so a 700x900 viewport is 1400x1800 px |
| `<name>.layout.json` | Tern's own layout JSON for that frame (every element's box), as the `shot` command writes it |
| `<name>.tree.txt` | the element tree the shot was taken from (what readiness waited for) |
| `<name>.hc.log` | every fake-`hc` invocation of the run, then the actions (`send`/`interrupt`/…) the block ran |
| `<name>.system.json` | Tern's native system-action log; external URL/file/reveal requests fail the run |
| `<name>.find.log` | artifact cases only: argv of genuine GNU `find` discovery calls, including a held/released stale-selection call |

The block opens **beside** the serve's startup shell, so the harness zooms its
pane (`tern` world command `zoom`) until the tab is zoomed on the Herd pane
before waiting, shooting or sending keys: every PNG is the block at full width.

## Isolation (hard requirements)

The user's Tern window and its daemon may be running with this plugin linked, so
every run gets its own everything:

- its own control socket, `<tmp>/ctl.sock` (never `/tmp/tern.sock`);
- its own `TERN_DAEMON_SOCKET` (`<tmp>/daemon.sock`), so `tern` verbs can't
  reach the live daemon (and the serve's window isn't reachable from them
  either — that is why the harness drives it through `ctl`);
- its own `TERN_CONFIG_DIR`, `XDG_STATE_HOME`, `XDG_DATA_HOME`,
  `XDG_CACHE_HOME` under `<tmp>`, so `tern.kv` (`hc_path`, scope state, activity) written by
  the block lands in the run's state, never in `~/.local/state/tern/plugin-data`;
- artifact-enabled runs additionally set only their serve's `HOME` to
  `<tmp>/home/alex` and `XDG_CONFIG_HOME` to `<tmp>/xdg/config`, overriding any
  inherited config-home path; the harness/hook `HOME`, live checksum roots and
  every other scenario's environment remain unchanged;
- `STENCIL_FIXTURE_ROOT=<tmp>/crates/tern`, so the plugin is loaded from the
  run's copy of `plugins/herd`, not the linked one;
- a fake `hc` first on `PATH`, as `<tmp>/bin/hc` (a wrapper that bakes the
  fixture and state paths in and execs `test/bin/hc`); the startup shell's
  `--out` and shutdown go with it, and a trap quits the serve, kills it if it
  hangs, and removes `<tmp>`;
- **the fake pinned as the plugin's own `hc`** (below), because `PATH` alone
  does not reach the panes the block splits;
- fake `xdg-open`, `gio`, `kde-open`, `kde-open5`, `gnome-open`,
  `sensible-browser`, `x-www-browser`, `google-chrome`, `google-chrome-stable`,
  `chromium` and `firefox` first on `PATH`, plus a fake `BROWSER`: they log
  argv to `actions.log` and exit harmlessly; any call fails the run;
- an invalid private `DBUS_SESSION_BUS_ADDRESS`, preventing the usual
  session-bus desktop portal path from reaching the real desktop;
- `tern ctl shot` writes inside `<tmp>/shots`, and the harness copies the PNG
  out: nothing is written to `~/target` or `target/shots/tern`.

The headless platform records its native `open-url`, `open-file` and `reveal`
operations in `ctl system`, even when it does not execute an OS opener. Every
successful screenshot run must have neither those operations nor fake opener
calls. `actions.sh` deliberately triggers each guard and checks it fails.
These are headless and PATH/session-bus defenses, not a syscall sandbox: they
do not intercept an arbitrary absolute browser executable or a program that
deliberately reconnects to the real D-Bus address. Never run a live-window
reproduction or send input to a real terminal.

### Why the fake is pinned in the plugin copy (`hc_path`)

The host half resolves `hc` from a candidate list (`M.HC` in
`plugins/herd/common.luau`: the bare name `"hc"`, then absolute paths) and
caches the winner in `tern.kv` as `hc_path`. Each action request carries that
resolved path to the **window** half, which turns it into a pane command:
`Enter` runs `<hc_path> attach --observe --history 200 ADDR`, `a` runs
`<hc_path> attach ADDR`. A split pane's shell gets the
**login** environment, not the serve's `PATH`, so a cached `"hc"` would resolve
to the user's real `~/.local/bin/hc` — a headless test would attach to a live
herd, and with `a` its keys would go into a real builder.

So `shoot.sh` patches the run's **copy** (`<tmp>/crates/plugins/fixtures/herd`,
never `plugins/`): one `table.insert(M.HC, 1, "<tmp>/bin/hc")` with the marker
comment `-- herd-shoot: pinned fake hc`, placed just before the module's
`return M`. That makes the absolute wrapper the first candidate regardless of
how the list is built, and it is idempotent (a second call finds the marker and
does nothing; a copy with two markers fails the run). If the list moves to
another file, the harness finds it by `M.HC` rather than by name; if it cannot
pin it with certainty the run **fails loudly** and shoots nothing.

Two assertions back it up, both before any key is sent:

1. after the block renders, the run's plugin `kv.json` (under
   `<tmp>/xdg/state/tern/plugin-data/herd/`) must say
   `hc_path == "<tmp>/bin/hc"`; anything else (the bare `"hc"`, a live path, no
   kv at all) fails the scenario;
2. `<name>.hc.log` must contain an `ls --json` line, so a PNG can never be the
   real herdr-core's data.

`test/bin/hc attach [--observe] [--history N] ADDR` answers the split itself:
it appends the argv to the actions log, prints
`FAKE hc attach <addr> (fixture <name>)` plus the fixture's
`read/<addr>.txt` when there is one, then `exec cat` so the pane stays open and
typing into it is harmless. The fake never execs a real `hc`.

```sh
./test/shoot.sh --keys "Enter sleep:1500" demo   # PNG: split right shows "FAKE hc attach t1n (fixture demo)"
./test/shoot.sh --keys "a sleep:1500" demo       # same banner, full attach (no --observe)
sed -n '/# actions/,$p' test/shots/demo-k-Enter_sleep_1500.hc.log
#   attach --observe --history 200 t1n
~/.local/bin/hc ls --json | jq '.terminals|length'  # unchanged before and after the run
```

Before and after the whole run, `shoot.sh` checksums `~/.local/state/tern/plugin-data`
and `~/.config/tern` (paths, sizes, mtimes, modes, sha256). It fails when the
diff mentions a harness path (that would mean the fake `hc`, or a temp dir, had
leaked into the live plugin's data); a diff without one is printed as the live
daemon's own writes. To check by hand:

```sh
find ~/.local/state/tern/plugin-data ~/.config/tern -type f ! -name '*.sock' ! -name '*.lock' -print0 |
  sort -z | xargs -0 sha256sum > /tmp/before
./test/shoot.sh demo empty error deep transitions
find ~/.local/state/tern/plugin-data ~/.config/tern -type f ! -name '*.sock' ! -name '*.lock' -print0 |
  sort -z | xargs -0 sha256sum > /tmp/after
diff /tmp/before /tmp/after        # the live herd console's own kv writes may show up; no /tmp/herd-shoot path may
```

The pin is what makes the block use the run's fake; `PATH` is only the second
line of defence (the host half's own `tern.process.run` inherits it). The
`hc_path` assertion and the `ls --json` line in `<name>.hc.log` are what make a
run prove it, so a PNG can never come from the real herdr-core.

## Fixtures

`test/fixtures/<name>/` — all files optional except one of `ls.json`/`seq/`:

| file | the fake `hc` answers |
| --- | --- |
| `ls.json` | `hc ls --json` |
| `full.json` | bare `hc --json`: full object envelope with `commands`, `hidden_finished`, `machines` and complete terminal records/labels, used once per requested run picker; fallback root `ls.json` is normalized to the same full shape without advancing any list sequence/failure counter |
| `ls-all.json` | `hc ls --all --json` (falls back to `ls.json`) |
| `seq/01.json`, `02.json`, … | one file per `ls` call, sticking on the last: status transitions over 2-second polls |
| `ls.exit` | exit with this code (on stderr: `ls.stderr`). Combined with `ls.fail-after N`, the first N calls succeed and later ones fail |
| `ls.stderr` | what a failing `hc` prints: `{"error":{"kind","message","hint"}}` |
| `get/<addr>.json` | `hc get <addr> --json`; no file → exit 3 with a `not_found` error |
| `get/<addr>.delay` | seconds to answer that `get` in (may be fractional), like a machine over a slow link |
| `get/<addr>.exit` | with `get/<addr>.stderr`: answer late, then fail with this exit code and that stderr |
| `get/<addr>.stderr` | what a failing `get` prints: `{"error":{"kind","message","hint"}}` |
| `scopes/<run>/ls.json`, `ls-all.json`, `seq/`, `ls.exit`, `ls.fail-after`, `ls.stderr` | the list dataset selected by `hc ls --label run=<run> --json` (also accepts `--label=run=<run>`); sequence/failure counters are independent per run |
| `scopes/<run>/get/<addr>.json`, `.delay`, `.exit`, `.stderr` | details for addresses unique to a scoped dataset; plain `hc get <addr> --json` searches these only when the main fixture has no detail for that address |
| `read/<addr>.txt` | `hc read <addr> --lines N` (`tail -n N` of it; ANSI allowed) |
| `expect` | regex the element tree must match before the shot (fixture-only text, e.g. a terminal address) |

An address is used as a path, so a machine-qualified one lands in a nested dir:
`build-box/t10` reads `get/build-box/t10.json` (or `.delay`/`.exit`/
`.stderr`) and `read/build-box/t10.txt`. No encoding step to remember.

The fixture root remains the **All terminals** dataset. A nonempty run label
selects only `scopes/<run>/`; an unknown run returns an empty list rather than
silently returning all terminals. Run names match directory basenames exactly.
The same list-file rules (`--all`, sequences, failures) apply inside each run
directory. Their counters live under the run's private
`HERD_FIXTURE_STATE/scopes/<run>/`, so switching scope cannot advance another
scope's sequence.

`full.json` is the unfiltered full-list response for cheap run-label discovery.
The fake preserves explicit names, argv and `labels: {"run":"…"}` while producing
the observed hc 0.1.18 object envelope: `commands`, `hidden_finished`, `machines`,
`terminals`. Terminal records contain the complete full-field set, nested
`foreground: {argv,cwd,name,pid}`, object/null `status`, and number/null `status_ms`,
not the short `ls.json` projection. Short fallback fixtures are normalized too.
This file is at the fixture root, never under a particular scope: discovering
another run must not depend on the current run.

Installed hc 0.1.18 was verified to support bare `hc --json` with this envelope and
labels objects; `hc --json --all` is invalid. None of the inspected real live or
retained finished records had `labels.run`. This verifies the discovery source,
not a live specific-run result. The `scopes` fixture supplies fictional cart and
checkout labels (plus an unlabelled retained shell) for behavioral coverage;
there is no fallback discovery command or per-row `get` sweep.

`hc get` itself takes no run label. Keep shared/canonical address details under
the fixture root's `get/`; these always win. Addresses present only in a scoped
dataset may put their details under that scope's `get/` (searched in pathname
order). Do not give a scope-only address conflicting detail files in multiple
scopes. `read/` remains at the fixture root.

`get/<addr>.delay` above the block's `GET_TIMEOUT_MS` (10 s) is what a `get`
that never answers looks like: the card turns red with
`hc get timed out after 10 s.` and the `.exit`/`.stderr` pair is never reached.
A delay under 10 s (or no `.delay`) shows the hc error JSON itself instead.

`hc send`, `hc interrupt`, `hc keys`, `hc kill` and `hc rm` only append to the
run's `actions.log` (kept as `<name>.hc.log`) and print `{"ok":true}`.
`hc attach [--observe] [--history N] ADDR` also appends, then prints
`FAKE hc attach <addr> (fixture <name>)` and `read/<addr>.txt` if the fixture
has one, and `exec cat`s so the split stays open — a pane the block split, never
a client of a real herdr-core terminal.

The block reads `hc get` for the selected row, so a fixture without
`get/<addr>.json` shoots a red `hc get (not_found)` line in the detail card. The
shipped fixtures cover the rows their cursor starts on (`t1n`, `t3n`, `t3s`,
`t2a`, `t3s1`); select another row and that line is the honest answer.

Shipped fixtures:

| fixture | shows |
| --- | --- |
| `demo` | the live herd's shape: `t1n` (hermes) and 8 codex builders in worktrees, working/blocked/done/idle + a plain `zsh` row with no status, `hidden_finished: 21`, `build-box` unreachable |
| `empty` | no live terminals; `ls-all.json` contains 5 already-finished fictional gates, hidden by default and visible with `h`, establishing history baselines without unread events |
| `error` | `hc ls` exits 3: the "can't list" card with hc's message |
| `deep` | 43 rows, 3 levels (lead → sub-lead → workers), a second root, standalone shells, an orphan whose parent isn't listed, very long names and worktree paths — the table has to scroll |
| `transitions` | `seq/01…04`: builders working → blocked → done, one finishing (`state: finished`) |
| `degraded` | one good list, then `hc ls` fails: the last list with the dock's warning over it |
| `remote` | the live herd plus a terminal on another machine, `build-box/t10` (address with a `/`, agent `bash`, cwd `/home/alex`, **no status**), and `machines[]` reporting `build-box` unreachable with `why`; `t43 b9-drafts` working. Its `get` takes `get/build-box/t10.delay` 12 s then `get/build-box/t10.exit` 1 + a `cannot reach build-box` error JSON, so the selected remote row's card shows the load, then `hc get timed out after 10 s.` |
| `activation` | fictional `spam-192` at `t44`, plus `cart #2 (review/ready)` at `build-box/t45`; action regression data, not a live terminal |
| `scopes` | All terminals contains `b1-cart` working, `b2-checkout` blocked and `b3-review` error; `scopes/cart/` contains only the cart builder and `scopes/checkout/` only checkout. Cart details are at the fixture root, checkout details are in its scope, and review's selected-card reply is delayed 2 s for scope-switch regression coverage |
| `activity` | baseline `t70` already finished plus four working builders; phase 02 blocks `t71`, finishes nonselected `t72` with exit 7, completes `t73`, and removes `t74`; phase 03 resumes `t71`, phase 04 completes it. Expected activity counts: 0 → 3 → 3 → 4 |
| `artifacts` | local `t81` has real private Report/Review/Brief files with `SHOOT_ARTIFACTS=1`; local `t82` has none; `build-box/t83` is remote. `review-001.md` is newer by mtime than the lexical decoy `review-999.md` |

Fake data is modelled on the real thing: `hc ls --json` is
`{hidden_finished, machines:[{name,since_ms,state,why}], terminals:[{address,agent,cwd,state,status,turn,where,name?,parent?}]}`
with `status` a string (`working|blocked|done|idle`, absent for a plain program)
and `state` `live|finished`; `get/` copies the real top-level keys
(`argv`, `cols`, `created_ms`, `cwd`, `exit_code`, `labels`, `parent`, `title`,
`turn`, and `status` as an object `{app,state}`).

### Add a fixture

```sh
mkdir -p test/fixtures/mine
$EDITOR test/fixtures/mine/ls.json          # copy a shipped one and edit
printf 'my-terminal\n' > test/fixtures/mine/expect
./test/shoot.sh mine                        # -> test/shots/mine.png
```

Then look at the PNG. If `expect` never matches, the run waits 30 s, prints a
warning and shoots anyway — if the redesign renames UI text, change the fixture's
`expect` to something from the data (an address, a name, `hidden_finished`).
`transitions` sequences are stateful per run: each invocation starts at `01`.

### Action regression checks

`./test/actions.sh` checks Enter and name-cell double-click each create exactly
one watch split, writable attach, confirmed send/interrupt, and a private git
worktree open. It measures key/click-to-visible-split wall time (limit 400 ms
with Herd focused) and simulated app time. Extra Enter/double-click cases
move focus away before consumption, exercising idle 2 Hz discovery followed
by 10 Hz pending-request polling and the 200 ms preference delay (1.2 s
simulated / 2.4 s wall-time ceilings, including discovery and layout settling).
It also checks acknowledgement clearing, first-claim
arbitration, refusal of another owner's acknowledgement, reload discarding
in-flight state, and a 5-second dock notice for missing/abandoned consumers.
Every normal run must pass the native/PATH opener guard.

Viewer cases use the `activation` fixture and the actual production mailbox,
pane-id registry and native layout APIs:

- `viewer-reuse`: repeated native Enter/name-cell double-click focuses the
  same read-only pane with exactly one `hc attach --observe --history 200`.
  Two writable Attach requests create separate panes; a later Watch still
  chooses the original read-only pane, not either writable attach.
- `viewer-reload`: reloading fixture plugins preserves the actual read-only
  pane identity and bounded persisted registry; the card's tiled controls
  converge after reload, and Watch does not attach again.
- `viewer-closed`: a genuinely closed viewer first removes all viewer controls,
  then is replaced exactly once with tiled controls, and subsequent Watch
  reuses its replacement.
- `viewer-replaced`: an unrelated `/bin/cat` terminal sets a matching OSC
  title, but is never adopted as a viewer. A native document replaces the
  real viewer's presentation; the test explicitly closes any old terminal
  retained in the deck before requiring a new Watch. The native file pane
  and its path remain untouched.
- `viewer-layout`: native `p` creates/floats a missing read-only viewer;
  `d` docks it and `z` parks it. The test asserts real
  `PaneInfo.floating`/`parked`/`tab` flags and that the pane has not exited.
  Rendered card action IDs must agree with `herd_viewer.state` and pane identity:
  absent/parked → no viewer controls; tiled → Float/Park; floating → Dock/Park.
  Already floating `p`, already tiled `d`, parked `p`/`d` and already parked `z`
  still dispatch and show the explicit dock notices without changing layout.
  Watch unparks/reuses the pane. The visible Float/Dock/Park host controls
  exercise the same production path without another fake attach.
  These new notice assertions use a real five-second deadline, matching the
  mailbox bound, rather than a count of `ctl wait`/tree loops. Passive tracing
  showed the host publishing a grant immediately while the next native window
  timer callback arrived 1.78–2.03 seconds later despite a 100 ms schedule.
  No stale root, cancelled timer, rejected notice or synthetic consumer was
  involved. These cases still use the production window's real timers; they
  assert completion, not a subsecond wake-up guarantee.
- `viewer-missing`: with no viewer, and with only a writable Attach, all viewer
  card controls must be absent. Dock and Park each show
  `No Watch viewer for spam-192 (t44). Open Watch first.` in the dock, without moving
  that writable pane, adding panes or attaching again. A changed notice between
  keys proves both refusals independently. A later Watch opens separately.
  The actual selected card must show unknown `Model` as `—` and `age unknown`.
- `viewer-reporter`: an actual Watch establishes `herd_viewer_owner`. Matching
  generation/selection/address/hc reports, claims and notices from a different
  owner must not erase its controls or replace the dock notice. Continuous
  checks span ordinary window ticks. Native float/dock/park calls outside the
  mailbox must update the rendered controls; reload, Watch unpark, native close
  and replacement must converge with exactly two real fake-hc attaches total.
- `viewer-lease`: a **protocol-only**, no-consumer run manually grants a reporter
  and reports `none`; it does not invent a viewer pane or mock a layout result.
  The granted owner reserves a read-viewer request: a foreign mailbox claim is
  refused, its own claim/ack succeeds, and the real host poll expires the
  abandoned three-second lease before a successor can claim. A second request
  holds its original execution grant across reporter expiry, within its native
  five-second request lifetime. The new reporter must neither regrant nor
  acknowledge it; only the original owner's delayed ACK clears it. Explicit
  lifetime assertions fail an overdue observation instead of accepting a
  naturally expired request as no-replay evidence. No terminal action may run.
  This tests host provenance and failover, not remote transport.

Native viewer cases never mock registry lookups or layout results; their
creation/reuse flows use the production mailbox. Only the explicitly named
provenance/lease checks submit protocol events to exercise rejection and expiry.
Native keys are sent only after refocusing the console; fake viewer processes
remain harmless. Fake-hc logs contain only expected read-only/writable attaches,
never send, interrupt, keys, kill or removal; the lease case permits no attaches.
All viewer waits use ordinary native timers: the cold-scope-only adapter is
not enabled or broadened. Existing opener guards remain mandatory.

Run just the viewer cases:

```sh
for action in viewer-reuse viewer-reload viewer-closed viewer-replaced viewer-layout viewer-missing viewer-reporter; do
  ACTION_CASE=$action SHOOT_SCOPE_OPEN_DRAIN=0 \
    SHOOT_HOOK='source "$TEST/actions-hook.sh"' ./test/shoot.sh activation
done
ACTION_CASE=viewer-lease SHOOT_NO_CONSUMER=1 SHOOT_SCOPE_OPEN_DRAIN=0 \
  SHOOT_HOOK='source "$TEST/actions-hook.sh"' ./test/shoot.sh activation
```

The competing-consumer setup copies every production Luau dependency into its
independent window-only fixture plugin, including `viewers.luau`; the manifest
does not activate a second host half.


Run-scope cases use the fictional `scopes` fixture to assert the rows actually
change, not just the title or outgoing `--label` argument. They cover the `u`
key, the Run… head action, typed labels, remembered choices through
`plugin.herd.scope`, All terminals, and unknown/empty runs. The head action is
sent directly through the production host event handler; key and palette cases
drive the production window picker. The cases also check selected-row-only
detail fetching, root `herd_scope`/`herd_summary` agreement, and simultaneous
Herd panes with different run counts (no cross-pane summary contamination).

The discovery case asserts no full-list request before the picker, then exactly
one bare `hc --json` request makes the unselected checkout builder's run label
available without requesting that builder's `get`. Selecting the discovered
choice must change the actual rows and scope summary. A later normal host poll
must not issue another full-list discovery request.
The separate fixture-shape assertion checks all four full-envelope keys, the
complete terminal-key set, foreground/labels types, object/null status and the
fictional `cart`/`checkout` run labels. It does not imply those labels existed in
the installed live data.

Reload cases assert `pane_scopes` and the 12-entry `recent_scopes` MRU persist.
Pending-request cases switch scopes with an unconsumed request, with real
send/interrupt confirmations open, and with a delayed selected-card `get` in
flight. A stale generation must be refused even after switching back to a run
that contains the original address; confirmations must never retarget a new
run's selected row. A separate confirmation case toggles Finished through the
host action (as another replica could) while the send confirmation is open:
changing list visibility must still permit exactly one send to the original
address. These cases use only the isolated control socket, fake hc and the
same opener guard as the other action checks.

Needs-you navigation cases also use `scopes`, through the production host and
window halves. They assert the root surface's selected address (`herd_cursor`),
not merely a notice or highlight:

- Console `]` / `[` and both palette actions (`plugin.herd.next_needs` /
  `plugin.herd.previous_needs`) cycle the blocked checkout and errored review
  builders forward/backward, including wrap.
- Working plus a cart-only subtree initially hides both targets. Navigation
  selects checkout, switches to Needs you and clears the subtree, making both
  eligible rows visible. A no-target cart scope instead preserves its Working
  filter/subtree and shows an explicit notice; checkout's sole eligible target
  can select itself in either direction. Neither scope leaks All terminals.
- `cx.actions:keys()` and `describe()` must agree that each global shortcut
  effectively resolves first to its Herd action. The test dispatches that
  highest-priority resolved action and verifies the selected address. Actual
  modified-key input is **not verified**: isolated Linux headless probes left
  both Herd J/U/H and the built-in New tab shortcut inert, even from a native
  file block, with key-window focus enabled, alternate modifier spellings,
  quoted combinations and separate keydown/up. This is a harness capability
  limitation, not evidence that a physical shortcut works or fails. Console
  brackets and palette actions remain behavioral tests; physical Linux and
  macOS shortcut dispatch require separate manual verification.
- A command from a separate tab running only `/bin/cat` focuses the most
  recently focused existing console, even with another console on a different
  run scope. A parked console is unparked/reused rather than duplicated.
- With no console, the command opens/focuses one. A release-file barrier in
  only that run's pinned fake-`hc` wrapper holds list replies until the test
  observes the initial loading notice, then releases the normal first list.
  One deferred navigation selects checkout exactly once across a later
  background poll; selecting review and reloading must preserve review rather
  than replay the launch navigation. The scope-change case switches to cart
  while the barrier is held, then releases both old/new list replies and asserts
  the deferred navigation was cleared. The private barrier fails after eight
  seconds, before the production host's ten-second list timeout.
- With no console, `plugin.herd.scope` opens a console and its real run picker.
  Choosing cart changes the rows; reloading preserves cart without reopening
  that launch picker or issuing another run-discovery request.
  That cold-scope case alone enables `SHOOT_SCOPE_OPEN_DRAIN=1`: its private
  window copy appends a harness-only command calling the existing production
  `wake_requests` callback, which UI waits explicitly invoke after fake-hc
  isolation is validated. Matched main/branch native cold-open/watch probes
  both reached a claimed but unacknowledged request after 1.4 seconds; the
  independent window VM did not reliably dispatch its callbacks. The adapter
  does not fake claims, acknowledgements, picker results or scope changes.
  Natural desktop wakeup and cold-open latency are **not verified** by this
  case. All other action/latency checks retain native timers; no-consumer and
  contender cases neither install nor invoke this adapter.
- A burst of 48 production `herd_next=1/-1` events immediately after a normal
  host poll adds no `hc ls` or full-list discovery call. The observation must
  finish before the next normal two-second timer; a slow observation fails
  explicitly rather than mistaking that timer for navigation-triggered polling.

Every navigation case rejects fake `send`, `interrupt` or `attach` calls and
retains the native/PATH external-opener guard. Selected-row detail `get`s and
normal background list polling are allowed; navigation never opens a viewer or
sends terminal input.

Activity cases use the **real production observation/event path**, not stubbed
ledger replies. They run `shoot.sh` with `SHOOT_PHASED=1`: the source fixture
is copied to `<tmp>/fixture`, its `seq/` is renamed `phases/` before the first
list, and phase 01 initializes `ls-all.json`. The hook atomically promotes
complete snapshots and requests a normal production Refresh, waiting for
surface/summary barriers. Extra timer polls therefore repeat the current
phase rather than consuming a transition early. The private copy also
contains cart/checkout datasets for scoped observations; the source fixture
never changes during a test.

- `activity-events` asserts the old finished terminal establishes a baseline
  with no event; blocked, done and a **nonselected finish with exit 7** are
  recorded even while `h` hides finished rows. A disappeared terminal never
  becomes a guessed finish. Repeating/resuming snapshots does not add events;
  working → done/idle and error transitions do. `h` changes presentation only:
  every production list still has `--all`, and there is no per-row `get`
  sweep. `v`, Escape and the head/back host actions open/close the inbox
  without marking read. Root `herd_activity`, `herd_unread`, `herd_inbox` and
  `herd_summary.unread` agree with metadata-only entries; unread keeps the
  native status segment visible after the last active terminal disappears.
  Selected-card text also distinguishes hc's matching `status_ms` as
  `for AGE (from hc)` from the subsequent blocked change as
  `for AGE (seen by Herd)`; unknown Model is `—`. These assertions read actual
  native card text, not diagnostic metadata.
- `activity-persistence` explicitly marks read, observes another event, and
  reloads the production plugin to assert the same IDs/read markers remain.
  It inspects only the private persisted ledger for forbidden terminal
  content fields. Clear must preserve persisted observation baselines;
  reloading identical blocked and error snapshots uses nonzero summary
  completion barriers to ensure cleared attention events never reappear.
- `activity-shared-scopes` creates two production consoles, mutes the first,
  and checks both still share the same deduplicated event IDs and unread
  counts. A selected `get`'s cached run label associates older events without
  claiming unknown run history; scoped observations associate a nonselected
  finish without fetching its details. Scoped Mark read/Clear resync both
  consoles without changing unrelated events; an unknown scope is empty.
  This checks history while muted, not toast delivery instrumentation.
- `activity-scope-order` holds a genuine scoped `hc ls` reply in this run's
  pinned wrapper, after recording its invocation and capturing its finished
  terminal response. Only then does All observe that finish. An All-only
  working marker terminal proves a newer All response completed before the
  older scoped response is released. The matching scoped response must still
  associate the nonselected finish with its run and unread count, without an
  extra event or detail fetch. The release barrier fails after eight seconds,
  before the production list timeout; neither sleeps nor synthetic ledger
  replies establish the ordering.

Run only these cases, still with the ordinary pin/isolation/opener guards:

```sh
for action in activity-events activity-persistence activity-shared-scopes activity-scope-order; do
  ACTION_CASE=$action SHOOT_PHASED=1 \
    SHOOT_HOOK='source "$TEST/actions-hook.sh"' ./test/shoot.sh activity
done
```

For an automatic-sequence visual preview instead, use
`./test/shoot.sh --keys "sleep:7000 v" activity`. This screenshot command is
not the deterministic regression test: the fake advances `seq/` on every
list call. Inbox history is observed metadata while consoles poll, not a
complete terminal audit.

Artifact cases run with `SHOOT_ARTIFACTS=1` and the real production permission
mailbox, filesystem helper, native configuration prompt and `cx.docs:open`.
The copied fixture's local cwd fields point to real private checkouts:

- `ARTIFACT_HOME=$T/home/alex`
- `ARTIFACT_ROOT=$ARTIFACT_HOME/code/shop/.worktrees/cart-totals`
- `ARTIFACT_MISSING=$ARTIFACT_HOME/code/shop/.worktrees/checkout-layout`

`shoot.sh` passes these shared variables to hooks; hooks must reuse them for
actual-file, native-document, mtime and stale-discovery assertions. Fixture
contents are copied into `$ARTIFACT_ROOT/.scratch` (no symlinks or old-path
aliases), while the missing peer is an empty directory. The source fixture
retains its fictional paths. Only this serve gets `HOME=$ARTIFACT_HOME` and a
private `XDG_CONFIG_HOME`, so the unchanged production host's native HOME-based
tilde handling renders `~/code/shop/.worktrees/cart-totals` in the selected card.
No plugin, source or display-text rewriting is used.

All seven artifact cases inspect the actual serve's `/proc/$SERVE_PID/environ`
(Linux) to prove its private HOME, config, XDG and socket settings, check physical
checkout paths under `$T`, and reassert exact `hc_path == "$T/bin/hc"` in private
KV plus a real fake-`hc` list invocation. They require the selected card's
rendered text to contain the expected tilde worktree and no `/tmp/` path,
including the missing checkout when selected. This reads only native
card text nodes, not inert surface metadata or absolute internal path properties.
The harness's original fake candidate pin and pre-hook KV guard are unchanged.

Mtimes explicitly make `review-001.md` newer than `review-999.md`. A private PATH
wrapper logs argv then runs `/usr/bin/find` unchanged; its stale-selection hold
targets `$ARTIFACT_ROOT`. It never invents matches or context replies. Native
file-pane paths and readable content, not a mocked open result, prove a document
opened.
Configuration is a global window preference: saving requires no Herd pane,
console focus or host configuration mailbox. Discovery and document opens
still use the real local-host permission path.

- `artifact-open` opens Report, newest-mtime Review and Brief through production
  host actions and asserts exact private paths, document kind and file text.
  Initial discovery invokes `find` once for the selected cwd, not every row.
- `artifact-mtime` changes real private review mtimes by one nanosecond at the
  current epoch, checks their stored nanoseconds with GNU `stat`, and selects
  `review-999.md` then `review-001.md` through genuine rescans and native file
  reads. An exact timestamp tie chooses lexical `review-001.md`. A same-second
  pre-epoch pair checks GNU find's signed-floor-seconds/positive-fraction
  ordering when GNU `touch` and the private filesystem preserve those times;
  unsupported pre-epoch precision is explicitly reported as a skipped subcase.
- `artifact-partial` saves four specs through the native preference prompt:
  missing slots 1/3, existing Review/Brief slots 2/4. Exactly the rendered
  `artifact=2` and `artifact=4` controls may exist, and those original actions
  must open the exact private Review/Brief paths and text. The missing
  `artifact=1` action still refuses to open; filtering never renumbers buttons.
- `artifact-missing-remote` selects the empty local cwd and asserts all three
  match slots lack paths, **zero rendered artifact buttons**, and no open.
  The remote hc row likewise has zero artifact buttons and yields an explicit
  local-only error with zero further `find` calls or file panes. A changed
  notice is the barrier before testing its separate refusal.
- `artifact-config` queries the native command palette for
  `Configure Herd artifacts`, waits for rendered command-label text outside
  input values, and presses native Enter once. The resulting native prompt
  saves a global custom link. Two real live Herd consoles must invalidate their
  old roots and refresh specs/results after both custom and `[]` saves, without
  changing the focused pane. The test opens the custom document and checks
  persistence after fixture reload. Invalid traversal and empty-object `{}`
  configurations preserve private KV and both consoles' live specs. `[]`
  disables discovery/opens and remains disabled after another reload. Native
  `select-text` replaces the focused prompt's prefilled ASCII JSON; no direct
  palette-action dispatch or synthetic configuration response substitutes for
  the visible palette/prompt path.
- `artifact-config-closed` closes the console and saves global preferences
  through the native palette/prompt while asserting that zero Herd panes
  exist. Only a separate explicit Open Herd action creates a console; it must
  then discover and open the configured Summary document. Reload retains the
  preferences without reopening their prompt.
- `artifact-stale` first observes the missing selection, then selects the
  populated cwd and holds its real `find` before execution. After a
  `find.started` barrier, the native selection changes back to the missing
  cwd; only then does `find.release` permit GNU `find` to return genuine old
  paths. `find.completed` and root selection/result barriers prove those
  paths never replace the current matches or open a document. The private
  hold is capped below the production two-second process timeout.

These cases do not invoke the cold-scope-only mailbox adapter or add a new
driver. Existing explicit-action mailbox assertions ignore automatic
`artifact_check` permission requests, not steering requests; the actual
production consumer must still answer permissions for discovery to finish.
Every case rejects fake terminal actions and retains the external-opener
guards. A genuinely remote **Tern host** is not available in this standalone
serve: its native-host ownership refusal remains unverified here, distinct
from the covered remote **hc address** refusal.

Run just the artifact cases:

```sh
for action in artifact-open artifact-mtime artifact-partial artifact-missing-remote artifact-config artifact-config-closed artifact-stale; do
  ACTION_CASE=$action SHOOT_ARTIFACTS=1 SHOOT_SCOPE_OPEN_DRAIN=0 \
    SHOOT_HOOK='source "$TEST/actions-hook.sh"' ./test/shoot.sh artifacts
done
```

For a static visual preview with real private files:
`SHOOT_ARTIFACTS=1 ./test/shoot.sh artifacts`.


`tern serve` is a standalone headless window, not a daemon session to which a
second real client can attach. The competing-consumer test instead loads a
second **independent VM running the unmodified production window half**;
both discover and claim the same production host mailbox. The focused
claim/ack tests also send two owners through the real serial host event
handler. This covers arbitration, not remote transport or a second OS window.
Headless `ctl carly lua` is used only for direct assertions/events; it does not
start an assistant process. The hook pumps the simulated clock for window
polling while using real sleeps for host expiry.

## How it drives a headless Tern

1. Copy `plugins/herd` into `<tmp>/crates/plugins/fixtures/herd` (the fixture
   plugins dir, `$STENCIL_FIXTURE_ROOT/../plugins/fixtures`), write the
   `<tmp>/bin/hc` wrapper, then pin the wrapper as the first `M.HC` candidate in
   the copy (fails the run if that cannot be done unambiguously).
2. Start `tern serve --control <tmp>/ctl.sock --out <tmp>/shots` with the
   isolated env from the section above, `<tmp>/bin` first on `PATH`.
3. `ctl plugins fixtures` (load/reload the fixture plugins), `ctl resize W H`
   when `--size`, `ctl plugins run plugin.herd.open`.
4. `ctl zoom` (retrying with `ctl focus next`) until `state` says the tab is
   zoomed and focused on the Herd pane.
5. Wait for readiness: poll `ctl tree` until it is non-empty, unchanged for two
   consecutive polls and matching `expect`, at most 30 s. Then assert the block's
   `kv.json` says `hc_path == "<tmp>/bin/hc"`; fail before any key otherwise.
6. Run the optional strict `SHOOT_HOOK`, then `--keys`: `ctl key COMBO` or
   `ctl dblclick CSS`, `sleep:MS` for a real pause or `wait:MS` for the simulated
   clock. Pump the simulated clock in 100 ms steps while settling the tree.
7. `ctl shot herd` (writes `<tmp>/shots/serve/herd.png` and `.layout.json`, and
   replies with both paths), copy them out, write `.tree.txt`, `.hc.log` and
   `.system.json`; fail if either opener guard recorded an external action.
8. `ctl quit`, wait for the process, `rm -rf <tmp>` — always, via `EXIT` trap in
   the per-scenario subshell.

Everything speaks the module ids the plugin uses: the block is `plugin.herd`
(`herd.herd`), its palette command `plugin.herd.open`.
