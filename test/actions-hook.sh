#!/usr/bin/env bash
# Sourced only by shoot.sh, after its fake-hc assertions. No live ctl endpoint.
set -euo pipefail
: "${T:?}" "${SOCK:?}" "${TERNFD:?}" "${ACTION_CASE:?}"
ctl() { "$TERNFD" ctl --control "$SOCK" "$@"; }
pump() { ctl wait 100 >/dev/null; sleep 0.025; }
wait_text() {
  for _ in {1..30}; do
    pump
    if ctl tree | grep -F "$1" >/dev/null; then return 0; fi
  done
  echo "missing UI: $1" >&2
  return 1
}
wait_action() {
  for _ in {1..30}; do
    pump
    if grep -qE "$1" "$T/state/actions.log" 2>/dev/null; then return 0; fi
  done
  echo "missing fake action: $1" >&2
  return 1
}
check_lua() {
  ctl carly lua "$(jq -Rn --arg code "$1" '$code')" >/dev/null
  if ! ctl carly ok; then
    ctl state | jq '.carly.last_tool' >&2
    return 1
  fi
  ctl carly close >/dev/null
}
probe='local p; for _, pane in cx.session:panes() do if pane.block == "herd.herd" or pane.block == "plugin.herd.herd" then p = pane.pane end end; assert(p); local root = cx.session:surface(p, {root="main", depth=0, nodes=1}).main; local q = root.p.herd_requests; '

case "$ACTION_CASE" in
  watch|doubleclick|attach)
    before=$(ctl state | jq '[.tabs[].panes] | add')
    start=$(date +%s%N)
    case "$ACTION_CASE" in
      watch) ctl key Enter >/dev/null ;;
      doubleclick) ctl dblclick '.sf-tbl-row.sel>.sf-tbl-c>.sf-t-strong' >/dev/null ;;
      attach) ctl key a >/dev/null ;;
    esac
    elapsed_app=0
    for _ in {1..12}; do
      ctl wait 25 >/dev/null
      elapsed_app=$((elapsed_app + 25))
      sleep 0.025
      after=$(ctl state | jq '[.tabs[].panes] | add')
      [ "$after" -gt "$before" ] && break
    done
    elapsed=$((($(date +%s%N) - start) / 1000000))
    [ "$after" -eq $((before + 1)) ] || { echo 'expected exactly one split' >&2; exit 1; }
    [ "$elapsed" -le 400 ] || { echo "split latency ${elapsed}ms exceeds 400ms" >&2; exit 1; }
    sleep 0.15
    if [ "$ACTION_CASE" = attach ]; then pattern='^attach t44$'; else pattern='^attach --observe --history 200 t44$'; fi
    [ "$(grep -cE "$pattern" "$T/state/actions.log")" -eq 1 ]
    check_lua "${probe}assert(#q == 0, 'ack did not clear request')"
    echo "$ACTION_CASE: one split, one fake attach; visible in ${elapsed}ms wall / ${elapsed_app}ms app time"
    ;;
  send)
    ctl key s >/dev/null
    wait_text 'Prompt for spam-192'
    ctl type '"Check the cart totals."' >/dev/null
    ctl key Enter >/dev/null
    wait_text 'Send this prompt with hc send?'
    ctl key Enter >/dev/null
    wait_action '^send t44 Check the cart totals\.$'
    echo 'send: confirmed prompt reached fake hc only'
    ;;
  interrupt)
    ctl key x >/dev/null
    wait_text 'Press the stop key in spam-192'
    ctl key Enter >/dev/null
    wait_action '^interrupt t44$'
    echo 'interrupt: confirmed action reached fake hc only'
    ;;
  worktree)
    ctl key w >/dev/null
    found=""
    for _ in {1..40}; do
      pump
      if ctl state | jq -e --arg path "$T/worktree" 'any(.git_blocks.blocks[]?; .repo.path == $path and .repo.ready)' >/dev/null; then
        found=1
        break
      fi
    done
    [ -n "$found" ] || { echo 'no private git block' >&2; exit 1; }
    echo 'worktree: private fixture repository opened in a git block'
    ;;
  arbitration|abandoned|reload)
    ctl key Enter >/dev/null
    sleep 0.1
    # No consumer runs in these cases. Exercise the real serial host, not a
    # mock implementation: first claim wins; wrong-owner ack cannot clear it.
    check_lua "${probe}assert(#q == 1); request_id = q[1].id; herd_pane = p; cx.session:event(p, {ev='action',id='main',act='herd_claim=' .. tern.json.encode({id=request_id,owner='first'})}); cx.session:event(p, {ev='action',id='main',act='herd_claim=' .. tern.json.encode({id=request_id,owner='second'})})"
    sleep 0.1
    check_lua "${probe}assert(#q == 1 and q[1].owner == 'first'); cx.session:event(p, {ev='action',id='main',act='herd_ack=' .. tern.json.encode({id=request_id,owner='second'})})"
    sleep 0.1
    check_lua "${probe}assert(#q == 1 and q[1].owner == 'first')"
    if [ "$ACTION_CASE" = arbitration ]; then
      check_lua "cx.session:event(herd_pane, {ev='action',id='main',act='herd_ack=' .. tern.json.encode({id=request_id,owner='first'})})"
      sleep 0.1
      check_lua "${probe}assert(#q == 0)"
      echo 'arbitration: first of two clients wins; wrong ack refused; correct ack clears'
    elif [ "$ACTION_CASE" = reload ]; then
      ctl plugins fixtures >/dev/null
      sleep 0.2
      check_lua "${probe}assert(#q == 0)"
      echo 'reload: in-flight grant discarded, not replayed'
    else
      sleep 5.1
      ctl tree | grep -q 'No Herd window completed watch'
      check_lua "${probe}assert(#q == 0)"
      echo 'abandoned window: grant expires with a dock notice, no replay'
    fi
    [ ! -s "$T/state/actions.log" ]
    ;;
  expire)
    ctl key Enter >/dev/null
    sleep 5.2
    ctl tree | grep -q 'No Herd window completed watch'
    check_lua "${probe}assert(#q == 0)"
    [ ! -s "$T/state/actions.log" ]
    echo 'no consumer: inert request expires with a dock notice'
    ;;
  *) echo "unknown action case: $ACTION_CASE" >&2; exit 2 ;;
esac
