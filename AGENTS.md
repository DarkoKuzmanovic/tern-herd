# AGENTS.md

Guide for coding agents (and people) changing this repo. Read it before editing; keep it true when
how things work changes.

## What this is

An unofficial Tern plugin for watching and steering herdr-core (`hc`) terminals and coding agents.
Tern owns the view; herdr-core owns the terminals. Closing the console or an attach split must not
stop an agent.

| Path | What |
|---|---|
| `plugins/herd/plugin.toml` | Manifest: plugin `herd`, block `herd.herd`, release version |
| `plugins/herd/host.luau` | Polling, tree, details, activity inbox, rendering, guarded send/interrupt |
| `plugins/herd/window.luau` | Palette commands, key bindings, mailbox actions, splits, dialogs, status segment |
| `plugins/herd/common.luau` | Shared constants, the single `M.HC` candidate list, quoting and links |
| `plugins/herd/activity.luau` | Shared capped metadata ledger, transition deduplication and read state |
| `plugins/herd/viewers.luau` | Bounded pane-id registry for read-only/writable viewers and verified host/session ownership |
| `plugins/herd/herd.css` | Scoped responsive layout |
| `plugins/herd/README.md` | Full behavior and limits |
| `test/shoot.sh`, `test/bin/hc` | Isolated headless screenshot runner and fake command |
| `test/typecheck.sh` | Pinned `luau-lsp analyze` over every `plugins/herd/*.luau` module |
| `.github/workflows/typecheck.yml` | The only CI job: runs `test/typecheck.sh` |
| `test/fixtures/` | Fictional `hc` replies, output and assertions |
| `docs/screenshots/` | Reviewed, metadata-stripped screenshots used by the root README |

## Ground rules

- **The plugin directory may be linked into a live Tern window.** Every save hot-reloads it.
  Use a working copy for substantial changes and copy back only a complete change. Never experiment
  with half-written code in the linked directory.
- **Check every Tern API against the generated types.** Run `tern plugin types /tmp/tern-types`
  and read its `tern.d.luau`; do not guess signatures, manifest keys or enum values. Keep generated
  types outside the repository. The host and window halves have different APIs.
- **Never send synthetic keys or text to a live window.** No live `tern ctl key` or `tern send`:
  focus may be a real agent's input. Interactive automation belongs only in `test/shoot.sh` with
  its private control socket. Restore focus with `tern focus`, not simulated keys.
- **Never touch real `hc` terminals in tests.** Use the existing harness, not a hand-written
  `tern serve` setup. It isolates config, state, data, cache and sockets, pins the absolute fake
  `hc` in the copied plugin and checks the cached `hc_path` before sending any key. A fake first
  on PATH alone is insufficient: split panes get the login environment.
- **Keep executable resolution in one place.** `M.HC` is defined only in `common.luau`, which
  ends with a module-level `return M`; the harness inserts its fake candidate before that return.
  Resolve by name, `$HOME/.local/bin/hc`, `/usr/local/bin/hc`, `/usr/bin/hc`; never hardcode a user.
- **No personal data in the repo.** No real home paths, hostnames, work sessions, customer/project
  names, credentials or terminal output in code, fixtures, docs or screenshots. Fixtures use
  `/home/alex`, repo `shop`, builders such as `b1-cart` and `b2-checkout`, and machine `build-box`.
  Before committing, privacy-grep the whole staged tree and history for home paths, emails,
  credentials, hostnames and real-work identifiers; inspect every match. `/home/alex` and the
  public owner's copyright, repository links and GitHub noreply commit identity are intentional.
  Open every screenshot; never publish a shot of the live window. Ignore `test/shots/`.
- **Keep actions explicit and safe.** Watch stays `--observe`; send/interrupt require confirmation,
  are rechecked against the current list, use argv rather than interpolated shell text and never
  add `--force`. Interrupt only working/blocked terminals. Local git blocks must not open remote
  paths as if they were local.
- **Keep lifecycle and rendering boring.** One state and poll timer per live pane, retire old state
  on reload and check liveness in callbacks. Rendering must not start processes. Reuse shared
  helpers and the current UI patterns; no unnecessary dependencies or bundled Tern binaries/assets.

## Checks

Run these from the repository root before committing:

```sh
shellcheck -S warning test/shoot.sh test/bin/hc test/typecheck.sh  # when shellcheck is installed
./test/typecheck.sh
./test/shoot.sh demo empty error deep transitions degraded remote
tern plugin reload herd
tern plugin list --json
```

Expect the harness to exit 0, Herd to be `ready` and `problems` is `[]`. `plugin list` checks
host loading; a broken window entry may only show in Tern's log as a missing palette command.
Check that **Open herd console** still opens/focuses it. Never send live keys to test that command.

A UI change also needs wide and narrow screenshots from sanitized fixtures, for example
`./test/shoot.sh --size 472x1240 demo`. Open the PNGs and inspect wrapping, selection, card layout,
scrolling and privacy. See [test/README.md](test/README.md) for interaction scenarios. Keep published
images under 300 KB, strip metadata and include only images the README uses.

`test/typecheck.sh` is the static gate: it downloads luau-lsp 1.70.1 and Tern's pinned
`tern.d.luau`, verifies both SHA-256 digests and runs `luau-lsp analyze` over every
`plugins/herd/*.luau` module — host, window, common and any helper a feature adds — so it exits
nonzero on any type error. It needs no Tern account or display, and `--defs
PATH` checks against a local `tern plugin types DIR` copy instead. Keep the pins in the script and
the docs in step when either is bumped. It reports drift in a module reaching
Tern's API with the wrong type; lint warnings alone do not fail it.

Only this static check runs in CI (`.github/workflows/typecheck.yml`). Tern is closed beta and
account-gated with no headless renderer in CI, so the screenshot harness stays local: record the
local Tern/hc versions, checks exercised and anything not tried; do not claim macOS support was
tested on Linux.

## Changelog

`CHANGELOG.md` follows Keep a Changelog. Every user-visible behavior change adds a line under
`## [Unreleased]` in the same commit, under `Added`, `Changed`, `Fixed` or `Removed`. Describe what
a user sees or does, not implementation details. Internal refactors, tests and docs-only changes
need no entry. Keep version headings and compare links current.

## Releases

Versions are `MAJOR.MINOR.PATCH`: new features bump MINOR, fixes bump PATCH, incompatible public
behavior changes bump MAJOR. A release is explicit and human-approved; local preparation is not
permission to publish.

1. Set `version` in `plugins/herd/plugin.toml` to `X.Y.Z`.
2. Turn the Unreleased entries into `## [X.Y.Z] - YYYY-MM-DD`, add an empty Unreleased section
   above them, and update the compare/tag links at the bottom.
3. Run the checks, inspect all shipped images and privacy-grep the final tree and history.
   Commit as `Release vX.Y.Z`, using the repository-local GitHub noreply identity.
4. After explicit publication approval, make an annotated tag and push the release commit/tag:
   `git tag -a vX.Y.Z -m vX.Y.Z`, then `git push origin main vX.Y.Z`.
5. Extract only that version's section from `CHANGELOG.md` into a notes file outside the repo,
   excluding its heading and link definitions, then publish those notes:
   `gh release create vX.Y.Z --title "vX.Y.Z" --notes-file /tmp/tern-herd-release-notes.md`.

Never rewrite a pushed tag or force-push `main`. Do not add a compatibility alias for a renamed
public interface: migrate callers and docs together.
