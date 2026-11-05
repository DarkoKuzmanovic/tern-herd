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
    echo 'unexpected terminal action reached fake hc' >&2
    return 1
  fi
}
wait_cursor() {
  local address_json cursor_probe=$probe
  address_json=$(jq -Rn --arg address "$1" '$address')
  if [ -n "${2:-}" ]; then
    cursor_probe="local p = $2; local root = cx.session:surface(p,{root='main',depth=0,nodes=1}).main; "
  fi
  for _ in {1..40}; do
    pump
    if check_lua "${cursor_probe}assert(root.p.herd_cursor == $address_json)" >/dev/null 2>&1; then return 0; fi
  done
  echo "navigation did not select '$1'" >&2
  ctl tree >&2
  return 1
}
assert_herd_focused() {
  ctl state | jq -e '.focused.label | startswith("Herd")' >/dev/null
}
list_calls() { grep -c '^ls ' "$T/state/invocations.log" || true; }
hold_private_lists() {
  # Hold only this run's already-pinned wrapper; never change resolution or
  # production code. Release after asserting the loading UI, not after a sleep.
  cp "$T/bin/hc" "$T/bin/hc-ready"
  {
    printf '#!/bin/sh\n'
    printf 'if [ "${1:-}" = ls ]; then\n'
    printf '  n=0\n'
    printf '  while [ ! -e "%s" ]; do\n' "$T/state/ls.release"
    printf '    if [ "$n" -ge 160 ]; then echo "private list barrier was not released within 8 seconds" >&2; exit 124; fi\n'
    printf '    n=$((n + 1)); sleep 0.05\n'
    printf '  done\n'
    printf 'fi\n'
    printf 'exec "%s" "$@"\n' "$T/bin/hc-ready"
  } >"$T/bin/hc"
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
  needs-cycle)
    wait_scope "" 1 1 1
    wait_cursor t61
    # The console keys must take the production BlockDef.key path.
    ctl key ']' >/dev/null
    wait_cursor t62
    ctl key ']' >/dev/null
    wait_cursor t63
    ctl key ']' >/dev/null
    wait_cursor t62
    ctl key '[' >/dev/null
    wait_cursor t63
    ctl plugins run plugin.herd.previous_needs >/dev/null
    wait_cursor t62
    ctl plugins run plugin.herd.next_needs >/dev/null
    wait_cursor t63
    no_terminal_actions
    echo 'needs cycle: console brackets and both palette actions cycle blocked/error in both directions with wrap'
    ;;
  needs-filter)
    wait_cursor t61
    ctl key 3 >/dev/null
    ctl key f >/dev/null
    wait_text 'focus b1-cart'
    # Both eligible targets are hidden by Working and by the cart subtree.
    ctl plugins run plugin.herd.next_needs >/dev/null
    wait_cursor t62
    wait_text 'Blocked or failed, waiting for you'
    tree=$(ctl tree)
    # Run-wide stats deliberately retain cart as the busiest terminal even
    # when filtered out. Assert table rows, not every name anywhere in the UI.
    rows=$(printf '%s\n' "$tree" | jq -r '.. | objects | select((.class? // "" | split(" ")) | index("sf-tbl-row")) | .. | objects | .text? // empty')
    [[ "$rows" = *b2-checkout* && "$rows" = *b3-review* && "$rows" != *b1-cart* ]] || {
      echo 'Needs you table did not replace the filtered cart subtree' >&2
      printf '%s\n' "$rows" >&2
      exit 1
    }
    [[ "$tree" != *'focus b1-cart'* ]]
    # The next target remains available after leaving the old subtree.
    ctl key ']' >/dev/null
    wait_cursor t63
    no_terminal_actions
    echo 'needs filter: hidden target selected, Needs you rows visible and cart subtree cleared'
    ;;
  needs-scopes)
    scope_event checkout
    wait_scope checkout 0 1 0
    ctl plugins run plugin.herd.next_needs >/dev/null
    wait_cursor t62
    ctl plugins run plugin.herd.previous_needs >/dev/null
    wait_cursor t62
    scope_rows checkout
    scope_event cart
    wait_scope cart 1 0 0
    ctl key 3 >/dev/null
    ctl key f >/dev/null
    wait_text 'focus b1-cart'
    ctl plugins run plugin.herd.next_needs >/dev/null
    wait_text 'No blocked or errored terminals in this scope'
    wait_cursor t61
    wait_text 'focus b1-cart'
    wait_text 'In a turn now'
    scope_rows cart
    ctl plugins run plugin.herd.previous_needs >/dev/null
    wait_text 'No blocked or errored terminals in this scope'
    wait_cursor t61
    scope_rows cart
    no_terminal_actions
    echo 'needs scopes: checkout sole target selects itself, cart has explicit no-target notice without leaking All rows'
    ;;
  needs-bindings)
    # Inspect effective resolution, not just source text or declared bindings.
    # Canonical chord spelling varies by platform, so compare normalized words.
    check_lua "local keys = cx.actions:keys(); for _, spec in {{'plugin.herd.next_needs','j'}, {'plugin.herd.previous_needs','u'}} do local action = cx.actions:describe(spec[1]); assert(action.id == spec[1] and action.available and #action.keys > 0); local found = false; for chord, ids in keys do local c = string.lower(chord); local modifier = string.find(c,'ctrl',1,true) or string.find(c,'cmd',1,true) or string.find(c,'control',1,true) or string.find(c,'command',1,true); if modifier and string.find(c,'alt',1,true) and string.find(c,'shift',1,true) and string.sub(c,-1) == spec[2] and ids[1] == spec[1] then assert(table.find(action.keys,chord), 'describe/keys disagree'); found = true end end; assert(found, 'effective global chord missing for ' .. spec[1]) end"
    # This Tern's headless modified-key input also misses built-in shortcuts.
    # Dispatch the effective chord's highest-priority action, not a hardcoded
    # substitute; plain console bracket input is covered by needs-cycle.
    check_lua "local ids = cx.actions:keys()['ctrl+alt+shift+j']; assert(ids and ids[1] == 'plugin.herd.next_needs'); cx.actions:run(ids[1])"
    wait_cursor t62
    check_lua "local ids = cx.actions:keys()['ctrl+alt+shift+u']; assert(ids and ids[1] == 'plugin.herd.previous_needs'); cx.actions:run(ids[1])"
    wait_cursor t63
    no_terminal_actions
    echo 'needs bindings: effective keys/describe agree and both highest-priority shortcut actions navigate; synthetic modifier input unverified'
    ;;
  needs-focus)
    # Two consoles make choosing the first enumerated pane insufficient.
    check_lua "${probe}needs_primary = p; needs_second = cx:new_block('herd.herd', nil, 'beside'); assert(needs_second)"
    for _ in {1..40}; do
      pump
      if check_lua "local r = cx.session:surface(needs_second,{root='main',depth=0,nodes=1}).main; assert(r.p.herd_cursor == 't61')" >/dev/null 2>&1; then break; fi
    done
    check_lua "cx.session:event(needs_second,{ev='action',id='main',act='herd_scope=' .. tern.json.encode('cart')}); cx.layout:focus(needs_primary)"
    pump
    check_lua "cx.layout:new_tab({command='exec /bin/cat'}); needs_other = cx.session:focused(); assert(needs_other and cx.session:tab_of(needs_other) ~= cx.session:tab_of(needs_primary))"
    ctl plugins run plugin.herd.next_needs >/dev/null
    assert_herd_focused
    wait_cursor t62 needs_primary
    check_lua "local a = cx.session:surface(needs_primary,{root='main',depth=0,nodes=1}).main.p; local b = cx.session:surface(needs_second,{root='main',depth=0,nodes=1}).main.p; assert(a.herd_cursor == 't62' and a.herd_scope == ''); assert(b.herd_cursor == 't61' and b.herd_scope == 'cart'); local count = 0; for _, pane in cx.session:panes() do if pane.block == 'herd.herd' or pane.block == 'plugin.herd.herd' then count += 1 end end; assert(count == 2)"
    no_terminal_actions
    echo 'needs focus: command from a separate private shell tab reuses the most recently focused console, not another scope'
    ;;
  needs-parked)
    check_lua "${probe}needs_parked = p; cx.layout:new_tab({command='exec /bin/cat'}); local ok, why = cx.layout:park(needs_parked); assert(ok, why); assert(cx.session:pane(needs_parked).parked)"
    ctl plugins run plugin.herd.previous_needs >/dev/null
    assert_herd_focused
    wait_cursor t63
    check_lua "${probe}assert(p == needs_parked and not cx.session:pane(p).parked)"
    no_terminal_actions
    echo 'needs parked: previous command unparks and focuses the original console without attaching'
    ;;
  needs-open|needs-loading-scope)
    hold_private_lists
    # Remove the console but keep a harmless private shell as the origin.
    check_lua "${probe}cx.layout:new_tab({command='exec /bin/cat'}); cx.layout:close(p)"
    ctl plugins run plugin.herd.next_needs >/dev/null
    assert_herd_focused
    wait_text 'Waiting for the first list; will select the next terminal that needs you.'
    if [ "$ACTION_CASE" = needs-open ]; then
      touch "$T/state/ls.release"
      wait_cursor t62
      # A deferred request is consumed once: later normal polls must not cycle.
      sleep 2.2
      wait_cursor t62
      check_lua "${probe}local count = 0; for _, pane in cx.session:panes() do if pane.block == 'herd.herd' or pane.block == 'plugin.herd.herd' then count += 1 end end; assert(count == 1)"
      # Keep a different saved cursor so replaying launch's "next" is visible.
      ctl plugins run plugin.herd.previous_needs >/dev/null
      wait_cursor t63
      ctl plugins fixtures >/dev/null
      wait_scope "" 1 1 1
      wait_cursor t63
      echo 'needs open: launch navigation applies once after the normal first list, not on later polls or reload'
    else
      scope_event cart
      check_lua "${probe}assert(root.p.herd_scope == 'cart')"
      touch "$T/state/ls.release"
      wait_scope cart 1 0 0
      wait_cursor t61
      scope_rows cart
      tree=$(ctl tree)
      [[ "$tree" != *'No blocked or errored terminals in this scope'* && "$tree" != *'Waiting for the first list'* ]]
      echo 'needs loading scope: changing scope clears deferred navigation before the new list applies'
    fi
    no_terminal_actions
    ;;
  needs-no-poll)
    # Start immediately after observing a normal list poll. The burst must
    # finish before the next 2-second host timer, avoiding an idle-poll race.
    before=$(list_calls)
    for _ in {1..120}; do
      pump
      [ "$(list_calls)" -gt "$before" ] && break
    done
    [ "$(list_calls)" -gt "$before" ]
    before=$(list_calls)
    start=$(date +%s%N)
    check_lua "${probe}for _ = 1, 24 do cx.session:event(p,{ev='action',id='main',act='herd_next=1'}); cx.session:event(p,{ev='action',id='main',act='herd_next=-1'}) end"
    sleep 0.15
    elapsed=$((($(date +%s%N) - start) / 1000000))
    [ "$elapsed" -lt 1500 ] || { echo "navigation polling observation took ${elapsed}ms; cannot exclude the normal timer" >&2; exit 1; }
    [ "$(list_calls)" -eq "$before" ] || { echo 'navigation started an hc ls instead of using the current list' >&2; exit 1; }
    if grep -q '^--json$' "$T/state/invocations.log"; then
      echo 'navigation started full-list discovery' >&2
      exit 1
    fi
    no_terminal_actions
    echo 'needs polling: 48 production host navigation events add no list/discovery calls between normal polls'
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
  scope-open)
    # Launch intent must survive block creation; an immediate session:event
    # can arrive before the new block has initialized and disappear.
    check_lua "${probe}cx.layout:new_tab({command='exec /bin/cat'}); cx.layout:close(p)"
    ctl plugins run plugin.herd.scope >/dev/null
    type_scope cart
    wait_scope cart 1 0 0
    wait_cursor t61
    scope_rows cart
    discovery_before=$(grep -c '^--json$' "$T/state/invocations.log" || true)
    ctl plugins fixtures >/dev/null
    wait_scope cart 1 0 0
    wait_cursor t61
    for _ in {1..8}; do pump; done
    check_lua "${probe}assert(#q == 0, 'launch scope picker replayed on reload')"
    tree=$(ctl tree)
    [[ "$tree" != *'Choose Herd run scope'* ]] || {
      echo 'launch scope picker reopened after plugin reload' >&2
      exit 1
    }
    [ "$(grep -c '^--json$' "$T/state/invocations.log" || true)" -eq "$discovery_before" ]
    scope_rows cart
    no_terminal_actions
    echo 'scope open: absent console opens its picker once, selects cart and does not replay the picker/discovery on reload'
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
