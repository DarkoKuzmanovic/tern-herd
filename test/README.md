# Headless screenshots of the Herd plugin

`test/shoot.sh` renders `plugins/herd` against **fixed, fake `hc` data** in a
throwaway `tern serve` and writes PNGs to `test/shots/`. It is the way to look
at the plugin's UI without a live herd, a live Tern window or a real
herdr-core, and the way to diff a redesign against the same fixtures.

Needs: `bash`, `jq`, `tern` on `PATH` (0.9.11 or newer; `TERN=/path/to/tern`
overrides), and a `hc`-shaped fixture — the real herdr-core is never started.

## Run

```sh
cd ~/code/tern-herd
./test/shoot.sh demo empty error deep transitions        # 5 PNGs
./test/shoot.sh --size 700x900 demo                      # narrow (700 CSS px)
./test/shoot.sh --keys "l" demo                          # a key first: the read card
./test/shoot.sh --keys "j j l" demo                      # a row further down (no read fixture -> error card)
./test/shoot.sh --keys "sleep:7000" transitions             # later `ls` answers from seq/ (real time)
./test/shoot.sh --keys "Enter sleep:1500" demo           # watch split: the fake attach banner
```

| option | meaning |
| --- | --- |
| `--size WxH` | viewport in CSS px (`resize W H`), e.g. `700x900`. Default: the serve's own, 1280x800 |
| `--keys "TOKEN …"` | tokens sent to the focused block with `tern ctl key` before the shot. Two pause tokens instead of a key: `wait:MS` and `sleep:MS` (below) |
| `SHOOT_KEEP=1` | keep the run's temp dir and leave the serve running (it prints the control socket); stop it yourself |
| `SHOOT_HOOK='…'` | run a shell snippet after the block opens, with `$T` (temp dir), `$SOCK` (control socket) and `$TERNFD` (the `tern` binary) set; its output is shown |

### `sleep:MS` vs `wait:MS`

The block polls `hc ls` from a **host timer on real time** (every 2 s). The two
tokens pause differently, and only one of them lets that poll happen:

| token | what it does | use it for |
| --- | --- | --- |
| `sleep:7000` | really sleeps 7 s in the harness, then the settle loop waits for what got painted | anything that depends on the host's own timers: a `seq/` fixture advancing (`transitions`), a notice expiring, the "finished hidden" count moving |
| `wait:3000` | `tern ctl wait 3000`: advances the serve's **simulated app clock** only | Tern-side animations/transitions that run on app time. It does **not** fire the block's 2 s poll, so `hc.log` gains no `ls` calls |

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
  `XDG_CACHE_HOME` under `<tmp>`, so `tern.kv` (`hc_path`, `summary`) written by
  the block lands in the run's state, never in `~/.local/state/tern/plugin-data`;
- `STENCIL_FIXTURE_ROOT=<tmp>/crates/tern`, so the plugin is loaded from the
  run's copy of `plugins/herd`, not the linked one;
- a fake `hc` first on `PATH`, as `<tmp>/bin/hc` (a wrapper that bakes the
  fixture and state paths in and execs `test/bin/hc`); the startup shell's
  `--out` and shutdown go with it, and a trap quits the serve, kills it if it
  hangs, and removes `<tmp>`;
- **the fake pinned as the plugin's own `hc`** (below), because `PATH` alone
  does not reach the panes the block splits;
- `tern ctl shot` writes inside `<tmp>/shots`, and the harness copies the PNG
  out: nothing is written to `~/target` or `target/shots/tern`.

### Why the fake is pinned in the plugin copy (`hc_path`)

The host half resolves `hc` from a candidate list (`M.HC` in
`plugins/herd/common.luau`: the bare name `"hc"`, then absolute paths) and
caches the winner in `tern.kv` as `hc_path`. The **window** half then turns that
string into a pane command: `Enter` runs `<hc_path> attach --observe --history
200 ADDR`, `a` runs `<hc_path> attach ADDR`. A split pane's shell gets the
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
| `ls-all.json` | `hc ls --all --json` (falls back to `ls.json`) |
| `seq/01.json`, `02.json`, … | one file per `ls` call, sticking on the last: status transitions over 2-second polls |
| `ls.exit` | exit with this code (on stderr: `ls.stderr`). Combined with `ls.fail-after N`, the first N calls succeed and later ones fail |
| `ls.stderr` | what a failing `hc` prints: `{"error":{"kind","message","hint"}}` |
| `get/<addr>.json` | `hc get <addr> --json`; no file → exit 3 with a `not_found` error |
| `get/<addr>.delay` | seconds to answer that `get` in (may be fractional), like a machine over a slow link |
| `get/<addr>.exit` | with `get/<addr>.stderr`: answer late, then fail with this exit code and that stderr |
| `get/<addr>.stderr` | what a failing `get` prints: `{"error":{"kind","message","hint"}}` |
| `read/<addr>.txt` | `hc read <addr> --lines N` (`tail -n N` of it; ANSI allowed) |
| `expect` | regex the element tree must match before the shot (fixture-only text, e.g. a terminal address) |

An address is used as a path, so a machine-qualified one lands in a nested dir:
`build-box/t10` reads `get/build-box/t10.json` (or `.delay`/`.exit`/
`.stderr`) and `read/build-box/t10.txt`. No encoding step to remember.

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
| `empty` | no terminals, 5 finished hidden |
| `error` | `hc ls` exits 3: the "can't list" card with hc's message |
| `deep` | 43 rows, 3 levels (lead → sub-lead → workers), a second root, standalone shells, an orphan whose parent isn't listed, very long names and worktree paths — the table has to scroll |
| `transitions` | `seq/01…04`: builders working → blocked → done, one finishing (`state: finished`) |
| `degraded` | one good list, then `hc ls` fails: the last list with the dock's warning over it |
| `remote` | the live herd plus a terminal on another machine, `build-box/t10` (address with a `/`, agent `bash`, cwd `/home/alex`, **no status**), and `machines[]` reporting `build-box` unreachable with `why`; `t43 b9-drafts` working. Its `get` takes `get/build-box/t10.delay` 12 s then `get/build-box/t10.exit` 1 + a `cannot reach build-box` error JSON, so the selected remote row's card shows the load, then `hc get timed out after 10 s.` |

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
6. `--keys`: `ctl key COMBO` per token, `sleep:MS` for a real pause (so the host's
   2 s poll runs) or `wait:MS` for the simulated clock, then wait for the tree
   to settle again.
7. `ctl shot herd` (writes `<tmp>/shots/serve/herd.png` and `.layout.json`, and
   replies with both paths), copy them out, write `.tree.txt` and `.hc.log`.
8. `ctl quit`, wait for the process, `rm -rf <tmp>` — always, via `EXIT` trap in
   the per-scenario subshell.

Everything speaks the module ids the plugin uses: the block is `plugin.herd`
(`herd.herd`), its palette command `plugin.herd.open`.
