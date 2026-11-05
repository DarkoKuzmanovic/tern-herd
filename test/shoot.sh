#!/usr/bin/env bash
# Deterministic screenshots of the herd plugin in a headless, fully isolated
# Tern. The plugin is copied into the run's fixture root, so whatever is in
# plugins/herd right now is what gets shot; nothing under plugins/ is touched.
#
#   test/shoot.sh [--size WxH] [--keys "TOKEN …"] <scenario>…
#
# Each scenario is a directory under test/fixtures/ (ls.json, ls-all.json,
# seq/, get/, read/, ls.exit, ls.stderr, expect). The fake hc in test/bin/hc
# answers `hc` from it, so the block renders fixture data, never the live herd.
#
# `--keys` tokens are pressed with `tern ctl key`; two pause tokens exist:
# `sleep:MS` (real time, so the block's 2 s host poll runs and a seq/ fixture
# advances) and `wait:MS` (`ctl wait`, the serve's simulated clock only).
# SHOOT_PHASED=1 copies a seq/ fixture privately, parks seq/ as phases/ and
# starts at phase 01. Hooks explicitly promote snapshots; idle polls cannot
# consume a later phase. The source fixture is never changed.
# SHOOT_ARTIFACTS=1 gives the artifacts fixture private real files/cwds,
# deterministic review mtimes and a logging wrapper around real GNU find.
# Hooks may hold one discovery call briefly to test stale-selection guards;
# no filesystem matches or document responses are fabricated.
#
# Isolated per run: control socket, TERN_DAEMON_SOCKET, TERN_CONFIG_DIR,
# XDG_STATE_HOME/DATA_HOME/CACHE_HOME, and a fake `hc` first on PATH.
# PATH does not reach the panes the block splits, so the run's copy of the
# plugin is also patched to make <tmp>/bin/hc the first `M.HC` candidate, and
# the run fails unless the block's kv `hc_path` is that same fake — otherwise a
# split would run the user's real hc and attach to the live herd.
# The live ~/.local/state/tern/plugin-data and ~/.config/tern are checksummed
# before and after and the run fails if anything there changed.
#
# Output: test/shots/<scenario>[-<size>][-k].png, plus the shot's layout JSON,
# the fake hc's call log and the element tree it was shot from.
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST=$REPO/test
FIXTURES=$TEST/fixtures
OUT=$TEST/shots
TERN=${TERN:-$(command -v tern || true)}
if [ -z "$TERN" ]; then
  echo "shoot: no tern on PATH (set TERN=/path/to/tern)" >&2
  exit 1
fi

SIZE=""
KEYS=""
SCENARIOS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --size)
      [ $# -ge 2 ] || { echo "shoot: --size needs WxH" >&2; exit 2; }
      SIZE=$2
      shift 2
      ;;
    --size=*) SIZE=${1#--size=}; shift ;;
    --keys)
      [ $# -ge 2 ] || { echo "shoot: --keys needs a string" >&2; exit 2; }
      KEYS=$2
      shift 2
      ;;
    --keys=*) KEYS=${1#--keys=}; shift ;;
    -h | --help)
      sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*) echo "shoot: unknown option $1" >&2; exit 2 ;;
    *) SCENARIOS+=("$1"); shift ;;
  esac
done
if [ ${#SCENARIOS[@]} -eq 0 ]; then
  echo "shoot: no scenario given (fixtures: $(ls "$FIXTURES" | tr '\n' ' '))" >&2
  exit 2
fi
case "$SIZE" in
  "") ;;
  [0-9]*x[0-9]*) ;;
  *) echo "shoot: --size wants WxH, e.g. 700x900" >&2; exit 2 ;;
esac
SW=${SIZE%x*}
SH=${SIZE#*x}

SUFFIX=""
[ -n "$SIZE" ] && SUFFIX="-$SIZE"
if [ -n "$KEYS" ]; then
  KEYS_SLUG=$(printf '%s' "$KEYS" | tr ' :' '__' | tr -cd 'A-Za-z0-9_-')
  SUFFIX="$SUFFIX-k-$KEYS_SLUG"
fi

mkdir -p "$OUT"

# Live Tern state this harness promises not to touch. Not the whole of
# ~/.local/state/tern: the live daemon rewrites daemon.state while it runs.
LIVE_DIRS=("$HOME/.local/state/tern/plugin-data" "$HOME/.config/tern")
sumtree() {
  local d
  for d in "${LIVE_DIRS[@]}"; do
    if [ -d "$d" ]; then
      (cd "$d" && find . -type f ! -name '*.sock' ! -name '*.lock' -printf '%p %s %T@ %m\n' | sort) || true
      (cd "$d" && find . -type f ! -name '*.sock' ! -name '*.lock' -print0 | sort -z | xargs -0 -r sha256sum) || true
    else
      echo "$d: absent"
    fi
  done
}
# The block caches the `hc` it found (kv `hc_path`, from its candidate list in
# plugins/herd/common.luau `M.HC`) and the window half runs that STRING in a
# split pane. A pane shell gets the login environment, not this serve's PATH, so
# a cached "hc" would resolve to the user's real herdr-core — a test would then
# attach to (and with `a`, type into) a live herd. Pin this run's fake `hc` as
# the FIRST candidate in the run's copy of the plugin; never shoot unpatched.
# pin_hc_candidate <plugin-copy-dir> <fake-hc-path>
pin_hc_candidate() {
  local dir=$1 wrapper=$2 files file n at ins marker
  case "$wrapper" in
    *[\"\'\\\&\|]*) echo "shoot: FAIL: fake hc path needs quoting: $wrapper" >&2; return 1 ;;
  esac
  marker='-- herd-shoot: pinned fake hc'
  # The file that owns the candidate list. It is common.luau today; the rewrite
  # may move it, so find it by what it does, not by name.
  files=$(grep -lE -- 'M\.HC' "$dir"/*.luau 2>/dev/null || true)
  if [ -z "$files" ]; then
    echo "shoot: FAIL: no file in $dir mentions M.HC; refusing to shoot unpatched" >&2
    return 1
  fi
  n=$(printf '%s\n' "$files" | wc -l)
  if [ "$n" -ne 1 ]; then
    echo "shoot: FAIL: M.HC appears in $n files of the plugin copy:" >&2
    printf '  %s\n' $files >&2
    return 1
  fi
  file=$files
  # Idempotent and unambiguous: one marker line, and it is this run's.
  n=$(grep -cF -- "$marker" "$file" || true)
  if [ "$n" -gt 0 ]; then
    if [ "$n" -eq 1 ] && grep -qF -- "table.insert(M.HC, 1, \"$wrapper\")" "$file"; then
      echo "shoot: already pinned $wrapper in ${file#"$dir"/}"
      return 0
    fi
    echo "shoot: FAIL: $file already carries $n '$marker' lines; refusing to shoot" >&2
    return 1
  fi
  # One insertion, right before the module's `return M`: independent of how the
  # list is built (a literal, table.insert, appended paths) and of the rewrite's
  # shape, and it puts the wrapper ahead of the bare "hc".
  at=$(awk '/^[[:space:]]*return[[:space:]]+M([[:space:]]|$)/ { n = FNR } END { print n + 0 }' "$file")
  if [ "$at" -le 0 ]; then
    echo "shoot: FAIL: no \`return M\` in $file to anchor the pin on; refusing to shoot unpatched" >&2
    return 1
  fi
  ins=$(printf '%s\ntable.insert(M.HC, 1, "%s")' "$marker" "$wrapper")
  awk -v at="$at" -v ins="$ins" 'NR == at { print ins } { print }' "$file" >"$file.pinned"
  mv "$file.pinned" "$file"
  n=$(grep -cF -- "$marker" "$file" || true)
  if [ "$n" -ne 1 ] || ! grep -qF -- "table.insert(M.HC, 1, \"$wrapper\")" "$file"; then
    echo "shoot: FAIL: pinning left $n marker lines in $file" >&2
    return 1
  fi
  echo "shoot: pinned $wrapper first in ${file#"$dir"/}"
}

# globals, not locals: the EXIT trap runs after shoot_one has returned
T=""
sock=""
serve_pid=""
live_before=$(sumtree)

# shoot_one <scenario>: renders one scenario in its own serve. Runs in a
# subshell so its temp dir and serve die with it whatever happens.
shoot_one() {
  local scen=$1 fix=$FIXTURES/$1 name encoded ok expect tree prev now stable png kvfile kvhc ms

  fix=$FIXTURES/$scen
  if [ ! -d "$fix" ]; then
    echo "shoot: no fixture $fix" >&2
    return 1
  fi
  name="$scen$SUFFIX"
  T=$(mktemp -d "/tmp/herd-shoot-$scen-XXXXXX")
  sock=$T/ctl.sock
  cleanup() {
    if [ -n "$serve_pid" ] && kill -0 "$serve_pid" 2>/dev/null; then
      "$TERN" ctl --control "$sock" quit >/dev/null 2>&1 || true
      for _ in 1 2 3 4 5 6 7 8 9 10; do
        kill -0 "$serve_pid" 2>/dev/null || break
        sleep 0.1
      done
      kill -0 "$serve_pid" 2>/dev/null && kill "$serve_pid" 2>/dev/null || true
      wait "$serve_pid" 2>/dev/null || true
    fi
    rm -rf "$T"
  }
  if [ -n "${SHOOT_KEEP:-}" ]; then
    trap 'serve_pid=""' EXIT
  else
    trap cleanup EXIT
  fi

  mkdir -p "$T/crates/tern" "$T/crates/plugins/fixtures" "$T/bin" "$T/xdg/state" \
    "$T/xdg/data" "$T/xdg/cache" "$T/config" "$T/shots"
  cp -r "${SHOOT_PLUGIN_DIR:-$REPO/plugins/herd}" "$T/crates/plugins/fixtures/herd"

  if [ -n "${SHOOT_WORKTREE:-}${SHOOT_PHASED:-}${SHOOT_ARTIFACTS:-}" ]; then
    cp -r "$fix" "$T/fixture"
    fix=$T/fixture
  fi
  if [ -n "${SHOOT_PHASED:-}" ]; then
    [ -f "$fix/seq/01.json" ] || { echo "shoot: phased fixture needs seq/01.json" >&2; return 1; }
    mv "$fix/seq" "$fix/phases"
    cp "$fix/phases/01.json" "$fix/ls-all.json"
    jq '.terminals |= map(select(.state != "finished"))' "$fix/ls-all.json" >"$fix/ls.json"
    # These private datasets exercise both observed scope membership and the
    # selected get's independent run=activity association.
    if [ "$scen" = activity ]; then
      mkdir -p "$fix/scopes/cart" "$fix/scopes/checkout"
      jq '.terminals |= map(select(.address == "t71" or .address == "t72"))' \
        "$fix/ls-all.json" >"$fix/scopes/cart/ls-all.json"
      jq '.terminals |= map(select(.address == "t73"))' \
        "$fix/ls-all.json" >"$fix/scopes/checkout/ls-all.json"
      for scope in cart checkout; do
        jq '.terminals |= map(select(.state != "finished"))' \
          "$fix/scopes/$scope/ls-all.json" >"$fix/scopes/$scope/ls.json"
      done
    fi
  fi
  if [ -n "${SHOOT_WORKTREE:-}" ]; then
    mkdir -p "$T/worktree"
    git -C "$T/worktree" init -q
    while IFS= read -r -d '' file; do
      jq --arg cwd "$T/worktree" 'walk(if type == "object" and has("cwd") then .cwd = $cwd else . end)' \
        "$file" >"$file.tmp"
      mv "$file.tmp" "$file"
    done < <(find "$fix" -name '*.json' -print0)
  fi
  if [ -n "${SHOOT_ARTIFACTS:-}" ]; then
    [ "$scen" = artifacts ] || { echo "shoot: artifact setup requires the artifacts fixture" >&2; return 1; }
    mkdir -p "$T/artifacts" "$T/artifacts-missing"
    cp -r "$fix/files/." "$T/artifacts/"
    # Git preserves content, not mtimes: the lower-numbered review is really
    # newer, so a lexical filename sort cannot accidentally pass the test.
    touch -t 202601010000 "$T/artifacts/.scratch/review-999.md"
    touch -t 202601020000 "$T/artifacts/.scratch/review-001.md"
    while IFS= read -r -d '' file; do
      jq --arg root "$T/artifacts" --arg missing "$T/artifacts-missing" \
        'walk(if type == "object" and has("cwd") then
          if .address? == "t81" then .cwd = $root
          elif .address? == "t82" then .cwd = $missing
          else . end
        else . end)' "$file" >"$file.tmp"
      mv "$file.tmp" "$file"
    done < <(find "$fix" -name '*.json' -print0)
  fi

  # The fake hc, with the fixture baked in: tern.process.run keeps only the env
  # it is given, so the paths must not depend on the serve process's env.
  {
    echo '#!/bin/sh'
    printf 'export HERD_FIXTURE=%q HERD_FIXTURE_STATE=%q\n' "$fix" "$T/state"
    printf 'exec %q "$@"\n' "$TEST/bin/hc"
  } >"$T/bin/hc"
  chmod +x "$T/bin/hc"
  # Absolute wrapper path first, so the kv the window half reads can only ever
  # be this run's fake. Fails the run when the plugin's list can't be pinned.
  if ! pin_hc_candidate "$T/crates/plugins/fixtures/herd" "$T/bin/hc"; then
    echo "shoot[$scen]: FAIL: could not pin the fake hc in the plugin copy" >&2
    return 1
  fi
  if [ -n "${SHOOT_NO_CONSUMER:-}" ]; then
    cp "$TEST/no-consumer.luau" "$T/crates/plugins/fixtures/herd/window.luau"
  elif [ -n "${SHOOT_CONTENDER:-}" ]; then
    # A second independent window VM consumes the same mirrored surface.
    # It uses the production consumer unchanged, including host arbitration.
    mkdir -p "$T/crates/plugins/fixtures/contender"
    cp "$T/crates/plugins/fixtures/herd/"*.luau "$T/crates/plugins/fixtures/contender/"
    printf '%s\n' 'schema = 1' 'id = "herd-contender"' 'name = "Test contender"' \
      'version = "0.0.0"' 'window = "window.luau"' >"$T/crates/plugins/fixtures/contender/plugin.toml"
  fi

  # A/B native cold-open/watch probes starve the independent window VM on
  # both main and this branch. Only the cold-scope regression may explicitly
  # drain the unchanged production consumer; ordinary action gates stay native.
  if [ "${SHOOT_SCOPE_OPEN_DRAIN:-0}" = 1 ]; then
    if [ "${ACTION_CASE:-}" != scope-open ] || [ -n "${SHOOT_NO_CONSUMER:-}${SHOOT_CONTENDER:-}" ]; then
      echo "shoot: cold-scope drain requires scope-open with one real consumer" >&2
      return 1
    fi
    printf '\n%s\n' \
      '-- herd-shoot: cold-scope-only headless driver, never shipped' \
      'tern.command({ id = "harness_drain", title = "Harness: drain cold-scope request", run = function(cx) wake_requests(nil, cx) end })' \
      >>"$T/crates/plugins/fixtures/herd/window.luau"
  fi

  # No desktop opener may escape this isolated process. Headless Tern also
  # records native shell requests (including ones that never spawn a process).
  mkdir -p "$T/state"
  if [ -n "${SHOOT_ARTIFACTS:-}" ]; then
    # This is a real GNU find adapter, never a synthetic scanner response.
    # Only this private Tern's PATH sees it; argv/stdout/status stay genuine.
    {
      printf '#!/bin/bash\n'
      printf 'printf "find" >>%q\n' "$T/state/find.log"
      printf 'printf " %%q" "$@" >>%q\n' "$T/state/find.log"
      printf 'printf "\\n" >>%q\n' "$T/state/find.log"
      printf 'if [ -e %q ] && [ "${2:-}" = %q ]; then\n' "$T/state/find.hold" "$T/artifacts"
      printf '  : >%q; n=0\n' "$T/state/find.started"
      printf '  while [ ! -e %q ]; do\n' "$T/state/find.release"
      printf '    if [ "$n" -ge 60 ]; then echo "private find barrier exceeded 1.5 seconds" >&2; exit 124; fi\n'
      printf '    n=$((n + 1)); sleep 0.025\n'
      printf '  done\n'
      printf 'fi\n'
      printf '/usr/bin/find "$@"\n'
      printf 'status=$?\n'
      printf ': >%q\n' "$T/state/find.completed"
      printf 'exit "$status"\n'
    } >"$T/bin/find"
    chmod +x "$T/bin/find"
  fi
  {
    echo '#!/bin/bash'
    printf 'printf "external-open %%q" "${0##*/}" >>%q\n' "$T/state/actions.log"
    printf 'printf " %%q" "$@" >>%q\n' "$T/state/actions.log"
    printf 'printf "\\n" >>%q\n' "$T/state/actions.log"
    echo 'exit 0'
  } >"$T/bin/external-open"
  chmod +x "$T/bin/external-open"
  for opener in xdg-open gio kde-open kde-open5 gnome-open sensible-browser \
    x-www-browser google-chrome google-chrome-stable chromium firefox; do
    ln -s external-open "$T/bin/$opener"
  done

  ctl() { "$TERN" ctl --control "$sock" "$@"; }

  STENCIL_FIXTURE_ROOT=$T/crates/tern \
    TERN_CONFIG_DIR=$T/config \
    TERN_DAEMON_SOCKET=$T/daemon.sock \
    XDG_STATE_HOME=$T/xdg/state \
    XDG_DATA_HOME=$T/xdg/data \
    XDG_CACHE_HOME=$T/xdg/cache \
    PATH=$T/bin:$PATH \
    BROWSER=$T/bin/external-open \
    DBUS_SESSION_BUS_ADDRESS=unix:path=$T/no-session-bus \
    HERD_FIXTURE=$fix \
    HERD_FIXTURE_STATE=$T/state \
    "$TERN" serve --control "$sock" --out "$T/shots" >"$T/serve.log" 2>&1 &
  serve_pid=$!

  ok=""
  for _ in $(seq 1 150); do
    if [ -S "$sock" ]; then ok=1; break; fi
    kill -0 "$serve_pid" 2>/dev/null || break
    sleep 0.1
  done
  if [ -z "$ok" ]; then
    echo "shoot[$scen]: serve never opened $sock" >&2
    sed 's/^/  serve: /' "$T/serve.log" >&2 || true
    return 1
  fi

  if ! ctl plugins fixtures >"$T/fixtures.out" 2>&1; then
    echo "shoot[$scen]: loading fixture plugins failed:" >&2
    sed 's/^/  /' "$T/fixtures.out" >&2
    return 1
  fi

  if [ -n "$SIZE" ] && ! ctl resize "$SW" "$SH" >"$T/resize.out" 2>&1; then
    echo "shoot[$scen]: resize $SW $SH failed:" >&2
    sed 's/^/  /' "$T/resize.out" >&2
    return 1
  fi

  if ! ctl plugins run plugin.herd.open >"$T/open.out" 2>&1; then
    echo "shoot[$scen]: plugin.herd.open failed:" >&2
    sed 's/^/  /' "$T/open.out" >&2
    return 1
  fi

  # Full width: the block opens beside the startup shell, so zoom its pane
  # (tern world command `zoom`) until the tab is zoomed on the Herd pane.
  zoomed=""
  for _ in 1 2 3 4; do
    ctl zoom >"$T/zoom.out" 2>&1 || true
    sleep 0.2
    st=$(ctl state 2>/dev/null || true)
    if printf '%s' "$st" | grep -q '"zoomed":true' && printf '%s' "$st" | grep -Eq '"focused":\{"id":[0-9]+,"label":"Herd'; then
      zoomed=1
      break
    fi
    ctl focus next >/dev/null 2>&1 || true
    sleep 0.1
  done
  if [ -z "$zoomed" ]; then
    echo "shoot[$scen]: WARNING: could not zoom the Herd pane; the block keeps its split" >&2
  fi

  [ -n "${SHOOT_KEEP:-}" ] && echo "shoot[$scen]: kept $T (control socket $sock)" >&2

  # Readiness: the tree holds still for two polls and, when the fixture has an
  # `expect`, shows something only that fixture can produce. No blind sleep.
  expect=""
  [ -f "$fix/expect" ] && expect=$(cat "$fix/expect")
  tree=""
  ready=""
  prev=""
  stable=0
  for _ in $(seq 1 150); do
    now=$(ctl tree 2>/dev/null || true)
    if [ "$now" = "$prev" ] && [ -n "$now" ]; then stable=$((stable + 1)); else stable=0; fi
    prev=$now
    if [ "$stable" -ge 2 ]; then
      if [ -z "$expect" ] || printf '%s' "$now" | grep -Eq -- "$expect"; then
        tree=$now
        ready=1
        break
      fi
    fi
    sleep 0.2
  done
  if [ -z "$ready" ]; then
    echo "shoot[$scen]: WARNING: no settled tree${expect:+ matching /$expect/} after 30s; shooting anyway" >&2
    tree=$prev
  fi

  # The isolation assertion: the block renders fine even when it found the real
  # hc, so check what it cached before any key can open a split. The window half
  # turns this value into a pane command, so anything but this run's fake is the
  # leak that once attached to a live herd.
  for _ in $(seq 1 25); do
    kvfile=$(grep -rlF --binary-files=text 'hc_path' "$T/xdg" "$T/config" 2>/dev/null | sed -n 1p || true)
    [ -n "$kvfile" ] && break
    sleep 0.2
  done
  kvhc=$(jq -r '.hc_path // empty' "$kvfile" 2>/dev/null || true)
  if [ "$kvhc" != "$T/bin/hc" ]; then
    echo "shoot[$scen]: FAIL: the block cached hc_path='${kvhc}' in ${kvfile:-no kv file under $T}" >&2
    echo "shoot[$scen]: FAIL: expected the run's fake hc ($T/bin/hc); refusing to shoot unpatched" >&2
    return 1
  fi
  echo "shoot[$scen]: hc_path is the run's fake hc"

  # Hooks may drive only this run, and only after fake-hc isolation is proven.
  if [ -n "${SHOOT_HOOK:-}" ]; then
    if ! TEST=$TEST T=$T SOCK=$sock TERNFD=$TERN KVFILE=$kvfile bash -euo pipefail -c "$SHOOT_HOOK" >"$T/hook.out" 2>&1; then
      sed 's/^/  hook: /' "$T/hook.out" >&2
      return 1
    fi
    sed 's/^/  hook: /' "$T/hook.out" >&2
  fi

  if [ -n "$KEYS" ]; then
    for encoded in $KEYS; do
      case "$encoded" in
        wait:*)
          # Simulated app clock only: advances the serve's own time. The host
          # half's 2 s `hc ls` poll is a real timer, so it does NOT fire here —
          # use sleep: for that.
          ctl wait "${encoded#wait:}" >/dev/null 2>&1 || true
          ;;
        sleep:*)
          # Real wall-clock sleep, so the block's tern.timer poll really runs
          # (and a seq/ fixture advances through its later answers); the settle
          # loop after the tokens then waits for what it painted.
          ms=${encoded#sleep:}
          case "$ms" in
            '' | *[!0-9]*) echo "shoot[$scen]: sleep: wants milliseconds, got '$ms'" >&2 ;;
            *) sleep "$(printf '%d.%03d' $((ms / 1000)) $((ms % 1000)))" ;;
          esac
          ;;
        dblclick:*)
          ctl dblclick "${encoded#dblclick:}" >"$T/key.out" 2>&1 || {
            echo "shoot[$scen]: double-click $encoded failed:" >&2
            sed 's/^/  /' "$T/key.out" >&2
            return 1
          }
          ;;
        *)
          if ! ctl key "$encoded" >"$T/key.out" 2>&1; then
            echo "shoot[$scen]: key $encoded failed:" >&2
            sed 's/^/  /' "$T/key.out" >&2
          fi
          ;;
      esac
    done
    # Let the last key's effect settle before the shot.
    prev=""
    stable=0
    for _ in $(seq 1 75); do
      ctl wait 100 >/dev/null
      now=$(ctl tree 2>/dev/null || true)
      if [ "$now" = "$prev" ] && [ -n "$now" ]; then stable=$((stable + 1)); else stable=0; fi
      prev=$now
      [ "$stable" -ge 2 ] && break
      sleep 0.2
    done
    tree=$prev
  fi

  if ! ctl shot herd >"$T/shot.out" 2>&1; then
    echo "shoot[$scen]: shot failed:" >&2
    sed 's/^/  /' "$T/shot.out" >&2
    return 1
  fi
  png=$(jq -r '.png // empty' "$T/shot.out" 2>/dev/null || true)
  layout=$(jq -r '.layout // empty' "$T/shot.out" 2>/dev/null || true)
  shotpix=$(jq -r 'if .size then "\(.size[0])x\(.size[1])" else "" end' "$T/shot.out" 2>/dev/null || true)
  if [ -z "$png" ] || [ ! -f "$png" ]; then
    echo "shoot[$scen]: shot wrote no png (reply: $(tr '\n' ' ' <"$T/shot.out"))" >&2
    find "$T/shots" -maxdepth 3 -printf '  %p\n' >&2 || true
    return 1
  fi
  cp "$png" "$OUT/$name.png"
  [ -n "$layout" ] && [ -f "$layout" ] && cp "$layout" "$OUT/$name.layout.json"
  {
    echo "# fixture $scen  shot ${shotpix:-?}  ${SIZE:+viewport $SIZE }${KEYS:+keys [$KEYS]}"
    echo "# invocations"
    cat "$T/state/invocations.log" 2>/dev/null || echo "(none)"
    echo "# actions (send/interrupt/keys/kill/rm)"
    cat "$T/state/actions.log" 2>/dev/null || echo "(none)"
  } >"$OUT/$name.hc.log"
  [ ! -f "$T/state/find.log" ] || cp "$T/state/find.log" "$OUT/$name.find.log"
  printf '%s\n' "$tree" >"$OUT/$name.tree.txt"
  ctl system >"$OUT/$name.system.json"
  if grep -q '^external-open ' "$T/state/actions.log" 2>/dev/null ||
    jq -e 'any(.log[]?; .op == "open-url" or .op == "open-file" or .op == "reveal")' "$OUT/$name.system.json" >/dev/null; then
    echo "shoot[$scen]: FAIL: external opener requested (see $name.hc.log and $name.system.json)" >&2
    return 1
  fi

  if ! grep -q '^ls ' "$T/state/invocations.log" 2>/dev/null; then
    echo "shoot[$scen]: FAIL: the fake hc was never asked for a list, so the block showed something else (real hc?)" >&2
    return 1
  fi

  echo "shoot[$scen]: $OUT/$name.png ($(wc -c <"$OUT/$name.png") bytes)"
}

fails=0
for scen in "${SCENARIOS[@]}"; do
  if ! ( shoot_one "$scen" ); then
    fails=$((fails + 1))
  fi
done

live_after=$(sumtree)
if [ "$live_before" != "$live_after" ]; then
  leakdiff=$(diff <(printf '%s\n' "$live_before") <(printf '%s\n' "$live_after") || true)
  if printf '%s' "$leakdiff" | grep -Eq 'herd-shoot|/test/bin/hc'; then
    echo "shoot: FAIL: live Tern state now mentions a harness path:" >&2
    printf '%s\n' "$leakdiff" >&2
    fails=$((fails + 1))
  else
    echo "shoot: live Tern state changed (the live daemon's own writes); no harness path in the diff:" >&2
    printf '%s\n' "$leakdiff" >&2
  fi
else
  echo "shoot: live Tern state unchanged (plugin-data, config)"
fi

if [ "$fails" -ne 0 ]; then
  echo "shoot: $fails scenario(s) failed" >&2
  exit 1
fi
