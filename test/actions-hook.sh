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
scope_event() {
  local run_json
  run_json=$(jq -Rn --arg run "$1" '$run')
  check_lua "${probe}cx.session:event(p, {ev='action',id='main',act='herd_scope=' .. tern.json.encode($run_json)})"
}
wait_scope() {
  local run=$1 working=$2 blocked=$3 errors=$4 run_json
  run_json=$(jq -Rn --arg run "$run" '$run')
  for _ in {1..40}; do
    pump
    if check_lua "${probe}local s = root.p.herd_summary; assert(root.p.herd_scope == $run_json); assert(s.run == root.p.herd_scope and s.working == $working and s.blocked == $blocked and s.errors == $errors)" >/dev/null 2>&1; then
      return 0
    fi
  done
  echo "scope/summary did not settle: '$run' ($working/$blocked/$errors)" >&2
  ctl tree >&2
  return 1
}
scope_rows() {
  local tree
  tree=$(ctl tree)
  case "$1" in
    cart) [[ "$tree" = *b1-cart* && "$tree" != *b2-checkout* && "$tree" != *b3-review* ]] ;;
    checkout) [[ "$tree" != *b1-cart* && "$tree" = *b2-checkout* && "$tree" != *b3-review* ]] ;;
    all) [[ "$tree" = *b1-cart* && "$tree" = *b2-checkout* && "$tree" = *b3-review* ]] ;;
    empty) [[ "$tree" != *b1-cart* && "$tree" != *b2-checkout* && "$tree" != *b3-review* ]] ;;
    *) return 2 ;;
  esac
}
type_scope() {
  wait_text 'Choose Herd run scope'
  ctl type '"Enter run label"' >/dev/null
  ctl key Enter >/dev/null
  wait_text 'Run label (run=…)'
  ctl type "$(jq -Rn --arg run "$1" '$run')" >/dev/null
  ctl key Enter >/dev/null
}
no_terminal_actions() {
  if grep -qE '^(send|interrupt|attach) ' "$T/state/actions.log" 2>/dev/null; then
    echo 'stale scope request reached fake hc' >&2
    return 1
  fi
}

case "$ACTION_CASE" in
  watch|doubleclick|attach|watch-unfocused|doubleclick-unfocused)
    before=$(ctl state | jq '[.tabs[].panes] | add')
    limit=400; steps=12
    if [[ "$ACTION_CASE" = *-unfocused ]]; then limit=2400; steps=52; fi
    start=$(date +%s%N)
    case "$ACTION_CASE" in
      watch|watch-unfocused) ctl key Enter >/dev/null ;;
      doubleclick|doubleclick-unfocused) ctl dblclick '.sf-tbl-row.sel>.sf-tbl-c>.sf-t-strong' >/dev/null ;;
      attach) ctl key a >/dev/null ;;
    esac
    # Emulate the originating replica losing focus before the only capable
    # consumer sees its grant. This touches only the private headless window.
    if [[ "$ACTION_CASE" = *-unfocused ]]; then ctl focus next >/dev/null; fi
    elapsed_app=0
    for ((step=0; step<steps; step++)); do
      ctl wait 25 >/dev/null
      elapsed_app=$((elapsed_app + 25))
      sleep 0.025
      after=$(ctl state | jq '[.tabs[].panes] | add')
      [ "$after" -gt "$before" ] && break
    done
    elapsed=$((($(date +%s%N) - start) / 1000000))
    [ "$after" -eq $((before + 1)) ] || { echo 'expected exactly one split' >&2; exit 1; }
    [ "$elapsed" -le "$limit" ] || { echo "split latency ${elapsed}ms exceeds ${limit}ms" >&2; exit 1; }
    if [[ "$ACTION_CASE" = *-unfocused ]]; then
      # Include initial idle discovery and asynchronous surface/layout turns.
      [ "$elapsed_app" -le 1200 ] || { echo "pending background handshake took ${elapsed_app}ms app time" >&2; exit 1; }
    fi
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
  scope-fixtures)
    # Exercise both --label spellings and canonical main-fixture get lookup.
    "$T/bin/hc" ls --json | jq -e '.terminals | length == 3' >/dev/null
    "$T/bin/hc" ls --label run=cart --json | jq -e '[.terminals[].address] == ["t61"]' >/dev/null
    "$T/bin/hc" ls --json --label=run=checkout | jq -e '[.terminals[].address] == ["t62"]' >/dev/null
    "$T/bin/hc" ls --label run=missing --json | jq -e '.terminals == []' >/dev/null
    "$T/bin/hc" --json | jq -e '[.terminals[].labels.run // empty] == ["cart","checkout"]' >/dev/null
    "$T/bin/hc" get t61 --json | jq -e '.labels.run == "cart"' >/dev/null
    "$T/bin/hc" get t62 --json | jq -e '.labels.run == "checkout"' >/dev/null
    echo 'scope fixtures: distinct lists, unknown run empty, main and scoped get resolution'
    ;;
  scope-discovery)
    wait_scope "" 1 1 1
    scope_rows all
    if grep -q '^--json$' "$T/state/invocations.log"; then
      echo 'run discovery happened without a picker request' >&2
      exit 1
    fi
    ctl key u >/dev/null
    wait_text 'Choose Herd run scope'
    wait_text 'Run checkout'
    # Checkout is not the selected row: its label must come from the one
    # full-list request, never an all-row get sweep.
    [ "$(grep -c '^--json$' "$T/state/invocations.log")" -eq 1 ]
    if grep -qE '^get t6[23] ' "$T/state/invocations.log"; then
      echo 'run discovery fetched unselected terminal details' >&2
      exit 1
    fi
    ctl type '"Run checkout"' >/dev/null
    ctl key Enter >/dev/null
    wait_scope checkout 0 1 0
    scope_rows checkout
    sleep 2.2
    wait_scope checkout 0 1 0
    [ "$(grep -c '^--json$' "$T/state/invocations.log")" -eq 1 ]
    echo 'scope discovery: one full-list request finds an unselected row label, not a get sweep or recurring poll'
    ;;
  scope-ui)
    wait_scope "" 1 1 1
    scope_rows all
    # Details are fetched for the selected row only, not every run candidate.
    if grep -qE '^get t6[23] ' "$T/state/invocations.log"; then
      echo 'scope enumeration fetched unselected terminal details' >&2
      exit 1
    fi
    ctl key u >/dev/null
    type_scope cart
    wait_scope cart 1 0 0
    scope_rows cart
    # The Run… head button dispatches this exact host action.
    check_lua "${probe}cx.session:event(p, {ev='action',id='main',act='scope'})"
    type_scope checkout
    wait_scope checkout 0 1 0
    scope_rows checkout
    ctl plugins run plugin.herd.scope >/dev/null
    wait_text 'Choose Herd run scope'
    ctl type '"Run cart"' >/dev/null
    ctl key Enter >/dev/null
    wait_scope cart 1 0 0
    scope_rows cart
    ctl plugins run plugin.herd.scope >/dev/null
    wait_text 'Choose Herd run scope'
    ctl type '"All terminals"' >/dev/null
    ctl key Enter >/dev/null
    wait_scope "" 1 1 1
    scope_rows all
    scope_event missing
    wait_scope missing 0 0 0
    scope_rows empty
    echo 'scope UI: key, head action, typed label, remembered palette choice and All terminals'
    ;;
  scope-reload)
    # The MRU stays bounded even when entered labels have no live terminals.
    for n in {1..13}; do
      scope_event "run-$n"
      wait_scope "run-$n" 0 0 0
    done
    check_lua "${probe}assert(#root.p.herd_scopes == 12); assert(root.p.herd_scopes[1] == 'run-13'); assert(not table.find(root.p.herd_scopes, 'run-1'))"
    scope_event cart
    wait_scope cart 1 0 0
    scope_rows cart
    ctl plugins fixtures >/dev/null
    wait_scope cart 1 0 0
    scope_rows cart
    check_lua "${probe}assert(#root.p.herd_scopes == 12 and root.p.herd_scopes[1] == 'cart')"
    kv=""
    while IFS= read -r -d '' candidate; do
      if jq -e --arg hc "$T/bin/hc" '.hc_path == $hc' "$candidate" >/dev/null 2>&1; then
        kv=$candidate
        break
      fi
    done < <(find "$T/xdg" "$T/config" -type f -print0)
    [ -n "$kv" ] || { echo 'no private Herd kv file with the pinned fake hc' >&2; exit 1; }
    jq -e '.recent_scopes | length == 12 and .[0] == "cart"' "$kv" >/dev/null
    jq -e 'any(.pane_scopes[]; .run == "cart")' "$kv" >/dev/null
    echo 'scope reload: selected run and bounded recent labels survive plugin reload'
    ;;
  scope-pending)
    # No window consumer: capture a genuine pending confirmation request.
    ctl key s >/dev/null
    sleep 0.1
    check_lua "${probe}assert(#q == 1 and q[1].verb == 'send'); old_generation = q[1].generation; old_address = q[1].address; assert(old_address == 't61' and type(old_generation) == 'number')"
    scope_event checkout
    wait_scope checkout 0 1 0
    check_lua "${probe}assert(#q == 0 and root.p.herd_generation ~= old_generation)"
    # Return to a list that contains the original address: membership alone
    # must not make the stale confirmation valid again.
    scope_event cart
    wait_scope cart 1 0 0
    check_lua "${probe}cx.session:event(p, {ev='action',id='main',act='herd_send=' .. tern.json.encode({address=old_address,text='Stale cart prompt',generation=old_generation})}); cx.session:event(p, {ev='action',id='main',act='herd_interrupt=' .. tern.json.encode({address=old_address,generation=old_generation})})"
    sleep 0.2
    no_terminal_actions
    check_lua "${probe}assert(#q == 0)"
    echo 'scope pending: queued request cleared and old send/interrupt generation refused after return'
    ;;
  scope-confirm-finished)
    ctl key s >/dev/null
    wait_text 'Prompt for b1-cart'
    ctl type '"Keep the cart target after Finished."' >/dev/null
    ctl key Enter >/dev/null
    wait_text 'Send this prompt with hc send?'
    # Another replica toggles list visibility, not the run scope. This must
    # not revoke an otherwise valid confirmation for the original address.
    check_lua "${probe}cx.session:event(p, {ev='action',id='main',act='finished'})"
    for _ in {1..30}; do
      pump
      if grep -q '^ls --json --all$' "$T/state/invocations.log"; then break; fi
    done
    grep -q '^ls --json --all$' "$T/state/invocations.log"
    ctl key Enter >/dev/null
    wait_action '^send t61 Keep the cart target after Finished\.$'
    [ "$(grep -c '^send ' "$T/state/actions.log")" -eq 1 ]
    wait_scope "" 1 1 1
    scope_rows all
    echo 'scope confirmation: Finished visibility toggle preserves the original send target'
    ;;
  scope-confirm-send|scope-confirm-interrupt)
    if [ "$ACTION_CASE" = scope-confirm-send ]; then
      ctl key s >/dev/null
      wait_text 'Prompt for b1-cart'
      ctl type '"Keep the original cart target."' >/dev/null
      ctl key Enter >/dev/null
      wait_text 'Send this prompt with hc send?'
    else
      ctl key x >/dev/null
      wait_text 'Press the stop key in b1-cart'
    fi
    scope_event checkout
    wait_scope checkout 0 1 0
    ctl key Enter >/dev/null
    for _ in {1..8}; do pump; done
    no_terminal_actions
    scope_rows checkout
    echo "$ACTION_CASE: open confirmation never retargets to the new run"
    ;;
  scope-detail)
    # Begin a slow selected-card get, then switch before its answer arrives.
    ctl key End >/dev/null
    for _ in {1..30}; do
      pump
      if grep -q '^get t63 ' "$T/state/invocations.log"; then break; fi
    done
    grep -q '^get t63 ' "$T/state/invocations.log"
    scope_event cart
    wait_scope cart 1 0 0
    sleep 2.2
    wait_scope cart 1 0 0
    scope_rows cart
    if ctl tree | grep -F 'Late review detail must not replace cart'; then
      echo 'old scope detail replaced the selected cart card' >&2
      exit 1
    fi
    echo 'scope detail: late old-run get cannot replace current rows, details or summary'
    ;;
  scope-summary)
    scope_event cart
    wait_scope cart 1 0 0
    check_lua "${probe}scope_first = p; scope_second = cx:new_block('herd.herd', nil, 'beside'); assert(scope_second)"
    for _ in {1..40}; do
      pump
      if check_lua "local r = cx.session:surface(scope_second, {root='main',depth=0,nodes=1}).main; assert(r.p.herd_summary.working == 1 and r.p.herd_summary.blocked == 1)" >/dev/null 2>&1; then break; fi
    done
    check_lua "cx.session:event(scope_second, {ev='action',id='main',act='herd_scope=' .. tern.json.encode('checkout')})"
    isolated=""
    for _ in {1..40}; do
      pump
      if check_lua "local a = cx.session:surface(scope_first, {root='main',depth=0,nodes=1}).main.p; local b = cx.session:surface(scope_second, {root='main',depth=0,nodes=1}).main.p; assert(a.herd_scope == 'cart' and a.herd_summary.run == 'cart' and a.herd_summary.working == 1 and a.herd_summary.blocked == 0 and a.herd_summary.errors == 0); assert(b.herd_scope == 'checkout' and b.herd_summary.run == 'checkout' and b.herd_summary.working == 0 and b.herd_summary.blocked == 1 and b.herd_summary.errors == 0)" >/dev/null 2>&1; then
        isolated=1
        break
      fi
    done
    [ -n "$isolated" ] || { echo 'two Herd pane summaries crossed scopes' >&2; exit 1; }
    echo 'scope summary: two simultaneous Herd roots keep independent scope counts'
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
