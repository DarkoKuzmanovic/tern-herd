# Changelog

What changed in each release of the Herd console, newest first. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow
[Semantic Versioning](https://semver.org/). User-visible changes go under **Unreleased**
in the same commit; see [AGENTS.md](AGENTS.md#releases).

## [Unreleased]

## [0.2.2] - 2026-11-05

### Fixed

- Watching a terminal by double-click or keyboard no longer also opens a system browser
  or duplicates the action when another Tern client is attached.
- Console action discovery backs off to twice per second while the console is unfocused,
  without delaying actions when focus returns or a background consumer has a pending request.

## [0.2.1] - 2026-11-05

First public release.

### Added

- A Tern block showing herdr-core terminals and coding agents as a parent–child tree, with
  status, turn counters, worktrees and machine warnings.
- All, Needs you, Working and Done filters; subtree focus and a switch to show finished terminals.
- A selected-terminal card with model, status age, parent, worktree and exit details, plus
  an on-demand card for the last 40 lines of output.
- Read-only watch and writable attach splits, confirmed send and interrupt actions, and a
  shortcut to open a local worktree in Tern's git block.
- Transition toasts, a mute switch and a status-line summary of working, blocked and errored agents.
- Responsive layouts for wide and narrow panes, keyboard navigation and saved view settings.
- Stale-data handling that keeps the last good terminal list visible when `hc` fails.
- An isolated headless screenshot harness with a fake `hc` and fictional fixtures for normal,
  empty, error, deep-tree, transition, degraded and remote-machine states.

[Unreleased]: https://github.com/DarkoKuzmanovic/tern-herd/compare/v0.2.2...HEAD
[0.2.2]: https://github.com/DarkoKuzmanovic/tern-herd/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/DarkoKuzmanovic/tern-herd/releases/tag/v0.2.1
