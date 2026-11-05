# Herd — hc terminals and agents in a Tern block

A Tern plugin that shows herdr-core's terminals (`hc ls --json`) in a block, so
a herd run (a lead agent and its builders in git worktrees) can be watched and
steered from Tern without typing `hc` commands.

```
Herd   herdr-core · updated 22:42:24                     [Finished h] [Mute m] [Refresh r]

Machines        Worktrees          Turns              Finished
2               9                  108                21
all connected   one per terminal   most 104 · t1n     hidden · h shows

 All   Needs you 1   Working   Done
Parents before their children · 9 of 9                  ┌ b1-cart  t3n          [Watch ⏎] ┐
Terminal              Agent    Status          Turn  Worktree │ Status    working · for 14m  │
t1n                   hermes   ● done            104 shop     │ Agent     codex              │
├─ b1-cart  t3n       codex    ● working 14m       1 cart     │ Model     gpt-6-astra        │
├─ b2-checkout t3p    codex    ● blocked  2m       2 checkout │ Worktree  ~/code/shop/…/cart │
└─ gate-cart t4a      sh       –                   0 cart     │ [Attach a] [Logs l] [Send… s] │
                                                              │ [Worktree w] [Focus f]        │
                                                              │               [Interrupt… x] │
                                                              └───────────────────────────────┘
↑↓ select  home/end jump  enter watch  1–4 tab filter
```

## The page

The block opens in Tern's sans face and follows Tern's page layout (Designing
Views):

- **Head row**: the title, `herdr-core · updated HH:MM:SS` (and `run <id>`
  when the block was opened with a `run=<id>` argument), and three controls:
  **Finished** (`h`, shows finished terminals with `hc ls --all`), **Mute**
  (`m`, turns the toasts off) and **Refresh** (`r`). Subtree focus appears in
  the head metadata as `focus <terminal>`. When `hc ls` fails after a list
  has loaded, the meta says `stale, 40s old` in the warning tone and the last
  list stays on screen.
- **Stats** (four tiles): facts about the run that the tabs don't already
  count. **Machines**: this one plus the remote machines hc lists (warning
  tone and "N unreachable" when hc can't reach some). **Worktrees**: distinct
  working directories of the listed terminals ("N shared" when terminals
  share one). **Turns**: hc's turn counters summed, with the busiest
  terminal. **Finished**: how many finished terminals `hc ls` hides (or, with
  `h` on, lists). The status counts live in the filter tabs instead: Tern's
  `StatItem` is only `label`, `value`, `sub`, `tone` and `title`, and a
  stats strip's actions fire for the whole strip, so a tile can't be a
  clickable filter with a selected state; tabs can.
- **Machines hc can't reach** each get a warning card with hc's reason and how
  long ago it went away.
- **Filter tabs**: All, Needs you (blocked, error), Working, Done (done,
  idle, finished). `1`–`4` or Tab/⇧Tab switch them.
- **The table**, full width, parents before their children with `├─ └─ │`
  connectors. Within a filter the tree is built from what the filter shows:
  a terminal whose parent is filtered out becomes a root.
  - Terminal: name and address (a nameless terminal shows its address). A
    named terminal on one of hc's remote machines always leads with its
    machine (`build-box/` then the name, and the local address after it
    when that fits), so the machine stays visible when the address is
    dropped for width.
  - Agent: Tern's own icon for programs it ships one for (`app-codex`,
    `app-hermes`, `app-omp`, `app-claude`, `pi-mark`, shells as `terminal`, …),
    otherwise just the name.
  - Status: a dot in the status tone, the word, and how long it has said it.
    working = info, blocked = warning (bold), error = error (bold), done =
    success, idle and finished = muted (the same tones in the status-line
    segment; info keeps working visibly apart from done's green). A finished
    terminal shows its exit code. Plain programs report no status and show
    `–`. The time is only shown
    once this block has *seen* the status change: a terminal seen for the
    first time (after opening the block or a reload) has no time, rather than a
    wrong one. Rows are never tinted.
  - Turn, right-aligned with its header (`align = "end"`, which Tern draws
    in tabular figures) in the mono face.
  - Worktree: the last segment of the working directory; the full absolute
    path is the row/cell tooltip. The card shows the whole directory with
    home abbreviated to `~`, on one line when it fits the card's value
    column and otherwise with the distinctive leaf on its own line.
  - Where: hc's `where`, only when the shown rows don't all say the same
    (a uniform value stays in the card and takes no room in the table).
- **The selected terminal's card**: beside the table in a wide pane, under it
  in a narrow one. Head: the name, address and agent icon, with the one
  primary action, **Watch** (Enter). Facts: status with how long and where
  that age comes from — `for 12m, per hc` is `hc get`'s own `status_ms` (when
  hc still reports the same word), `for 3m, seen here` is a change this block
  saw between two polls, and `since unknown` is neither (never `created_ms`);
  the blocked kind; what the
  program says, agent (and the foreground program when it differs), model
  (from the command line's `-m`/`--model`), turn, started (relative),
  exit code / signal / reason once finished, parent, number of children,
  full worktree path, where, and the `run` label. Until the first `hc get`
  answers, the facts start with a shimmering fetching message
  (`Fetching details from build-box…`,
  without the machine for a local one) and the facts that need it read
  `fetching…`; after a failure they say what is missing and hc's error shows
  under them. Its buttons come in fixed
  groups: **Attach**, **Logs**, **Send…** (what reaches the terminal), then
  **Worktree** and **Focus** (where to look), then **Interrupt…** alone at
  the end of its own row. A button that can't apply is disabled with the
  reason.
- **Logs card**: `l` reads the last 40 lines once (`hc read <t> --lines 40`)
  into a card under the view, in a box half the pane tall that opens at the
  newest line and scrolls up. `l` again reads again; nothing polls it.
- **Dock**: a one-line notice (sent, interrupted, refused, left the list),
  the refresh problem while a stale list shows, and a legend of only the keys
  that have no button on screen: ↑↓ select, Home/End jump, Enter watch and
  1–4/Tab filter (every other action shows its keycap on its button).

### Width

The block measures each column's widest cell (headers included) on every
render, in one pass over the shown rows, and picks what fits instead of
letting the table hide columns on its own:

- Terminal, Status and Worktree always show. A worktree name longer than 24
  characters is cut in the middle; the full path is the tooltip and is in the
  card. Tree connectors take two cells per level. A name longer than 36 cells
  (less its connectors, never under 12) and a `where` longer than 24 are cut
  with "…" and shown whole in the cell's tooltip, so one long value can't
  push the other columns out.
- Then, while they fit: Turn, Agent, Where (only when the rows' `where`
  differ), then the address after each name (also in the card's head).
  What doesn't fit is still in the card (the table's priorities follow the
  same order, so if Tern runs short it drops Where, then Agent, then Turn).
- The card sits beside the table (40–48ch) only when the table keeps
  Terminal, Status, Worktree, Turn and Agent next to it; otherwise it goes
  under the table at full width.
- The head always keeps its action labels. Native flex wraps the actions
  below the title (and the buttons themselves if needed) at the actual
  available width; it does not use `cx.cols` to decide whether they fit.
  The stats strip compresses into four equal-width tiles on one row, with
  ellipsized sub-lines and full tile tooltips rather than an accidental
  three-plus-one wrap. The strip and first tile align with the title gutter.
  The keyboard legend is shorter in compact layouts.
- The card's Worktree line estimates its value column from the card's width
  (48 cells beside the table, the pane less its padding under it) less the
  card's insets, the key column and the gap, and breaks before the leaf only
  when the full `~` path is longer than that.
- Height comes from the window's actual layout, not a `cx.rows` budget.
  A small scoped stylesheet (`herd.css`) gives the page's native flex column
  the region's real bounds. The head, stats, machine cards, tabs, selected
  card, optional logs and dock take their natural measured sizes; the table
  receives the remaining height, capped only at its full content height.
  Its header plus 4 rows is a minimum, not the normal allocation. If even
  that minimum cannot fit, the page itself scrolls instead of losing the
  card. Overflowing tables have a persistent scrollbar at the right edge.
  The ordered tree and all connectors are built
  before clipping; scrolling never turns an intermediate sibling into the
  last sibling. Selection stays in view. `cx.rows` counts terminal cells,
  not the sans line units used by view extents.

### States

- Loading (first list on its way): skeleton tiles and rows.
- Error with nothing loaded: an error card in the view's place with hc's own
  message (`{error: {kind, message, hint}}`), the first 200 bytes of anything
  that isn't JSON, and Retry. No `hc` at all: the card says where it looked.
- Empty: no live terminals → an inline empty state (with **Show finished**
  when hc hides some); a filter with no match → the table's empty line.

## Install

```sh
tern plugin link ~/code/tern-herd/plugins/herd   # use it in place
tern plugin list                                 # herd … ready
```

`tern plugin unlink herd` removes it. After editing the files, `tern plugin
reload herd`.

Open it with the palette command **Open herd console** (`plugin.herd.open`),
or **Ctrl+Alt+Shift+H** (⌘⌥⇧H on macOS). The command focuses (or unparks) the
Herd block already in the window, or opens one beside the focused pane.

While a Herd block is open, the status line shows `herd N working`
(`· M blocked`, `· K error`): error tone with errors, else warning with
blocked terminals, else info while something works; clicking it focuses the
block.

## Keys

| Key | Does |
| --- | --- |
| ↑ ↓ / k j, Home End / g G, PgUp PgDn | move the selection |
| 1 2 3 4, Tab ⇧Tab | filter: All, Needs you, Working, Done |
| Enter / o (or double-click a row) | watch: `hc attach --observe --history 200 <t>` in a split to the right. Nothing you type reaches the agent and the terminal isn't resized |
| a | attach: `hc attach <t>` in a split, to type into it |
| l | logs: `hc read <t> --lines 40` once into a card; `l` again re-reads |
| s | send: asks for a prompt, asks again to confirm, then runs `hc send <t> <text>` (never `--force`) |
| x | interrupt: asks to confirm, then runs `hc interrupt <t>`. Refused for done, idle and finished terminals, and checked again after you confirm |
| w | worktree: opens a git block on the terminal's working directory (`cx.git:open`, beside). Local terminals only |
| f | focus: show only the selected terminal and its descendants; `f` again clears it |
| h | show or hide finished terminals (`hc ls --all`) |
| m | mute or unmute toasts |
| r | refresh now |
| Esc | close the logs card, then clear the focus |

Only `s` and `x` change anything, and both ask first. `ctrl+\` detaches from an
attach split (hc's key); closing the split also only detaches, the terminal
keeps running.

The filter, focus, finished and mute settings and the selected terminal are
saved, so a reload or restart keeps them.

## Toasts

After the first list (never on it), the block toasts status changes it sees
between two polls:

- a terminal turns **blocked** (info toast) or **error** (error toast), or
  first appears in one of them;
- **working → done** (success) and **working → idle** (info);
- **finished** (success for exit 0, else error).

Each change toasts once per status (the same snapshot twice, or the same
status from two sources, doesn't repeat it). `m` mutes them. Turning `h` on or
off takes the next list as a new baseline, so old finished terminals don't
toast as they appear.

Tern's toast levels are `success`, `info` and `error` only (`ToastLevel` in
`tern.d.luau`); there is no warning toast, so blocked is an info toast while
the table and status segment show it in the warning tone.

**Finishing is only partly visible.** Plain `hc ls` leaves finished terminals
out, so a terminal that disappears from the list can't be assumed to have
finished. The block does not guess: with `h` on, finished terminals stay in
the list and their finish toasts like any change; with `h` off, only the
*selected* terminal is checked when it disappears (one `hc get`), which
toasts and notes "finished with exit N" or says it left the list. Other
terminals that finish while `h` is off just leave the table.

## How it works

- `host.luau` (runs in the Tern daemon) defines the block `herd.herd`, polls
  `hc ls --json` (`--all` with `h`, `--label run=<id>` with a `run=<id>`
  block argument) every 2 s with one `tern.timer` per live block and
  `tern.process.run` (10 s timeout), and runs `hc get`, `hc read`, `hc send`
  and `hc interrupt`. It finds `hc` by name, then at `$HOME/.local/bin/hc`,
  `/usr/local/bin/hc` and `/usr/bin/hc` (a daemon started by a launcher may
  have a short PATH).
- An `hc ls` answer identical to the last one is not parsed again. Parsing,
  the tree and the view are linear in the number of terminals.
- Status ages: the host keeps, per address, the last status and when it
  changed (`since`); a new address has no `since`. This lives only in the
  block, so a reload starts again without times.
- The card's `hc get <address> --json` runs only for the selected terminal:
  200 ms after the selection stops moving, and then at most once every 10 s
  while it stays selected (each poll asks; a cached answer younger than 10 s
  wins). Answers are cached per address and dropped when the terminal leaves
  the list. Rendering never starts a process.
- A host block can't split panes, open dialogs or open a git block; only the
  window half can. It queues a request in inert main-region metadata.
  `window.luau` reads only that root (`cx.session:surface`, depth 0, one node)
  and asks the serial host worker to claim a request. The host grants it to
  the first claimant; only that window acknowledges and executes the split,
  prompt, picker or git open. Other replicas, including clients without the
  window plugin, do nothing. No internal action uses a URL or system opener.
  Unlike a file-local kv queue, surface metadata also reaches remote replicas;
  unlike kv get/set, the host's claim arbitration is not a read/write race.
- Action discovery reads only the root (no descendants or table cells):
  10 Hz while a Herd pane has the window's current focus or this consumer is
  waiting on a request it might handle; otherwise idle at 2 Hz.
  It stops when no Herd block exists in the current session. Focus/lifecycle
  events cancel the old timer and read immediately, so returning to the
  console does not wait for a background tick. Tern exposes no surface-update
  event; the tiny steady-state read discovers requests without a URL effect.
  Focus is read from `cx.session:focused()`, not the remembered per-tab pane
  flag. Focused consumers claim immediately; others defer at least 200 ms.
  An unfocused consumer discovers idle requests on a 500 ms tick, then polls
  every 100 ms through the preference delay and claim/grant handshake until
  that request leaves the list. The idle rate stays at 2 Hz.
  The API does not expose which window originated a host key or row event,
  so focus is a preference, not a guarantee about the originating replica.
- Acknowledgements clear requests. Uncompleted requests expire after 5 s
  with a dock notice, so a missing consumer or a window closing mid-request
  does not wedge the queue. Requests are not saved across block restarts;
  a fresh window VM identity cannot replay its predecessor's grant. A
  confirmed send or interrupt still returns through `cx.session:event`,
  and the host rechecks it against the latest list before running `hc`.
- The status segment reads counts the host writes to `tern.kv` (`summary`:
  working, blocked, errors; only when they change) on a 3-second window timer,
  and shows only while a Herd block is open in the window.
- A pane id survives a block restart or plugin reload: the host keeps one
  state object per pane, retires the old one in `init` (cancelling its poll
  and debounce timers), and every timer or process callback checks it is still
  the live run before touching it.

## Limits

- **Local only.** The host half runs `hc` on the machine whose daemon runs the
  block. Viewing a remote Tern host runs that machine's `hc`, if it has one.
  hc's own remote machines (`hc machine`) appear as rows (`machine/t7`) when
  hc lists them, and unreachable ones as warning cards. `w` refuses remote
  terminals: `cx.git` reads local repositories only, and is desktop-only.
- Window-only actions need at least one desktop replica with Herd's window
  half installed and the console's session open. A web client runs no Lua:
  without a capable replica, actions expire with a notice rather than
  launching a browser. With multiple capable replicas, one executes each
  action; a crash between acknowledgement and execution can lose that action,
  but it is never replayed automatically. Try it again explicitly.
- Finished terminals: see the caveat under Toasts.
- `tern plugin list` reports the host half only: a syntax error in
  `window.luau` shows up as a log warning (`plugin window entry failed to
  load`) and a missing palette command.

## Testing headless

From the repository root, use the isolated fixture harness:

```sh
./test/shoot.sh demo
./test/shoot.sh --size 472x1240 demo
./test/shoot.sh --keys "2" demo
./test/shoot.sh --keys "sleep:2100" transitions
./test/shoot.sh --keys "dblclick:.sf-tbl-row.sel" activation
./test/actions.sh
```

Screenshots are written to `test/shots/`. See [the test harness README](../../test/README.md)
for fixtures, interaction keys, and isolation guarantees.

The harness copies the plugin into a temporary environment, pins its fake
`hc` as the first executable candidate, and asserts that the plugin's
`hc_path` kv value resolves to that fake before sending any keys. It also
isolates `TERN_CONFIG_DIR`, `XDG_STATE_HOME`, `XDG_DATA_HOME`,
`XDG_CACHE_HOME`, and `TERN_DAEMON_SOCKET`, and uses a unique control socket.
This keeps `tern.kv` writes out of the live plugin-data directory and makes
watch/attach/send/interrupt tests use fixture terminals rather than the live
herd.

Do not substitute a hand-written `tern serve` recipe that isolates only
`TERN_CONFIG_DIR`: kv writes can still reach the live state directory.
With the real `hc`, watch/attach splits reach the live herd even when the
Tern window is headless.
