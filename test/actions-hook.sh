#!/usr/bin/env bash
# Sourced only by shoot.sh, after its fake-hc assertions. No live ctl endpoint.
set -euo pipefail
: "${T:?}" "${SOCK:?}" "${TERNFD:?}" "${ACTION_CASE:?}"
ctl() { "$TERNFD" ctl --control "$SOCK" "$@"; }
pump() { ctl wait 100 >/dev/null; sleep 0.025; }
wait_text() {
  for _ in {1..30}; do
    # This adapter exists only in scope-open's private window copy, and this
    # hook runs only after shoot.sh validates its pinned fake hc. It invokes
    # the real production consumer, not synthetic claims or picker results.
    if [ "$ACTION_CASE" = scope-open ] && [ "${SHOOT_SCOPE_OPEN_DRAIN:-0}" = 1 ]; then
      ctl plugins run plugin.herd.harness_drain >/dev/null
    fi
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
probe='local p; for _, pane in cx.session:panes() do if pane.block == "herd.herd" or pane.block == "plugin.herd.herd" then p = pane.pane end end; assert(p); local root = cx.session:surface(p, {root="main", depth=0, nodes=1}).main; local q = {}; for _, request in root.p.herd_requests do if request.verb ~= "artifact_check" then table.insert(q, request) end end; '
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

# Activity cases never let the fake's automatic seq counter drive the test.
# shoot.sh parks snapshots under this run's fixture/phases before Tern starts.
wait_lua() {
  for _ in {1..60}; do
    pump
    if check_lua "$1" >/dev/null 2>&1; then return 0; fi
  done
  echo "surface assertion did not settle: $1" >&2
  ctl tree >&2
  return 1
}
activity_root='local root = cx.session:surface(activity_primary,{root="main",depth=0,nodes=1}).main; '
activity_event() {
  local act_json
  act_json=$(jq -Rn --arg act "$1" '$act')
  check_lua "cx.session:event(${2:-activity_primary},{ev='action',id='main',act=$act_json})"
}
wait_activity() {
  local pane=${3:-activity_primary}
  wait_lua "local root = cx.session:surface($pane,{root='main',depth=0,nodes=1}).main; assert(#root.p.herd_activity == $1 and root.p.herd_unread == $2); assert(root.p.herd_summary.unread == $2)"
}
activity_phase() {
  local phase=$1
  [ -f "$T/fixture/phases/$phase.json" ]
  # Atomic replacement: a background poll can only read a complete snapshot.
  cp "$T/fixture/phases/$phase.json" "$T/fixture/ls-all.next"
  mv "$T/fixture/ls-all.next" "$T/fixture/ls-all.json"
  jq '.terminals |= map(select(.state != "finished"))' \
    "$T/fixture/ls-all.json" >"$T/fixture/ls.next"
  mv "$T/fixture/ls.next" "$T/fixture/ls.json"
  for scope in cart checkout; do
    if [ "$scope" = cart ]; then
      jq '.terminals |= map(select(.address == "t71" or .address == "t72"))' \
        "$T/fixture/ls-all.json" >"$T/fixture/scopes/$scope/ls-all.next"
    else
      jq '.terminals |= map(select(.address == "t73"))' \
        "$T/fixture/ls-all.json" >"$T/fixture/scopes/$scope/ls-all.next"
    fi
    mv "$T/fixture/scopes/$scope/ls-all.next" "$T/fixture/scopes/$scope/ls-all.json"
    jq '.terminals |= map(select(.state != "finished"))' \
      "$T/fixture/scopes/$scope/ls-all.json" >"$T/fixture/scopes/$scope/ls.next"
    mv "$T/fixture/scopes/$scope/ls.next" "$T/fixture/scopes/$scope/ls.json"
  done
  activity_event refresh
}
activity_baseline() {
  [ -f "$T/fixture/phases/01.json" ] && [ ! -d "$T/fixture/seq" ]
  check_lua "${probe}activity_primary = p"
  wait_activity 0 0
  wait_cursor t71 activity_primary
  wait_lua "${activity_root}assert(root.p.herd_summary.working == 4)"
  wait_lua "${activity_root}assert(table.find(root.p.herd_scopes,'activity'))"
  # The old finished terminal is really in the all-list response, not omitted
  # to make a false initial-unread assertion pass.
  jq -e 'any(.terminals[]; .address == "t70" and .state == "finished")' \
    "$T/fixture/ls-all.json" >/dev/null
}
activity_no_sweep() {
  local selected_pattern=${1:-'^get t71 --json$'}
  # Selected-card t71 is permitted; no activity observer may fetch another
  # terminal, including a disappeared row, just to infer a finish.
  if grep '^get ' "$T/state/invocations.log" | grep -vE "$selected_pattern"; then
    echo 'activity fetched unselected terminal details' >&2
    return 1
  fi
  if grep '^ls ' "$T/state/invocations.log" | grep -vE '^ls --json --all( --label run=.+)?$'; then
    echo 'activity observation omitted --all' >&2
    return 1
  fi
  no_terminal_actions
}
activity_metadata() {
  check_lua "${activity_root}local ids = {}; local last = math.huge; for _, e in root.p.herd_activity do assert(type(e.id) == 'number' and not ids[e.id]); ids[e.id] = true; assert(type(e.at) == 'number' and e.at > 1000000000 and e.at <= last); last = e.at; assert(type(e.address) == 'string' and type(e.status) == 'string' and type(e.read) == 'boolean' and type(e.runs) == 'table'); for key in e do assert(table.find({'id','at','address','name','from','status','exit_code','runs','read'},key), 'non-metadata activity field: ' .. key) end end"
}

# Viewer tests always send native keys to the console, never to a viewer's
# harmless fake attach. They observe real panes/flags and the real mailbox;
# no registry result, grant, acknowledgement or layout response is mocked.
viewer_root='local root = cx.session:surface(viewer_source,{root="main",depth=0,nodes=1}).main; '
viewer_initialize() {
  check_lua "${probe}viewer_source = p; assert(root.p.herd_cursor == 't44' and #q == 0)"
}
viewer_press() {
  check_lua "cx.layout:focus(viewer_source)"
  ctl key "$1" >/dev/null
}
viewer_event() {
  local verb_json
  verb_json=$(jq -Rn --arg verb "$1" '$verb')
  check_lua "cx.layout:focus(viewer_source); cx.session:event(viewer_source,{ev='action',id='main',act=$verb_json})"
}
viewer_new() {
  local key=$1 variable=$2
  check_lua "viewer_before = {}; viewer_before_count = 0; for _, pane in cx.session:panes() do viewer_before[pane.pane] = true; viewer_before_count += 1 end; cx.layout:focus(viewer_source)"
  ctl key "$key" >/dev/null
  wait_lua "${viewer_root}assert(#root.p.herd_requests == 0); local panes = cx.session:panes(); assert(#panes == viewer_before_count + 1); local created; for _, pane in panes do if not viewer_before[pane.pane] then assert(created == nil); created = pane end end; assert(created and (created.kind == 'terminal' or created.kind == 'agent') and created.exited == nil); $variable = created.pane"
}
viewer_reuse() {
  local key=${1:-Enter}
  check_lua "viewer_reuse_count = #cx.session:panes(); cx.layout:focus(viewer_source)"
  if [ "$key" = doubleclick ]; then
    ctl dblclick '.sf-tbl-row.sel>.sf-tbl-c>.sf-t-strong' >/dev/null
  else
    ctl key "$key" >/dev/null
  fi
  wait_lua "${viewer_root}assert(#root.p.herd_requests == 0 and cx.session:focused() == viewer_read); assert(#cx.session:panes() == viewer_reuse_count); local pane = cx.session:pane(viewer_read); assert(pane and not pane.parked and pane.exited == nil)"
}
viewer_counts() {
  local reads=$1 writes=$2 observed_reads observed_writes
  for _ in {1..30}; do
    pump
    observed_reads=$(grep -c '^attach --observe --history 200 t44$' "$T/state/actions.log" 2>/dev/null || true)
    observed_writes=$(grep -c '^attach t44$' "$T/state/actions.log" 2>/dev/null || true)
    if [ "${observed_reads:-0}" -eq "$reads" ] && [ "${observed_writes:-0}" -eq "$writes" ]; then
      if [ -s "$T/state/actions.log" ] && grep -vE '^(attach --observe --history 200 t44|attach t44)$' "$T/state/actions.log"; then
        echo 'viewer layout action sent input or stopped a terminal' >&2
        return 1
      fi
      return 0
    fi
  done
  echo "viewer fake-attach counts did not settle: read ${observed_reads:-0}/$reads, write ${observed_writes:-0}/$writes" >&2
  return 1
}

# Artifact cases use private files and real discovery/document APIs. No context
# response, filesystem match, mailbox acknowledgement or document result is faked.
artifact_root='assert(artifact_source and cx.session:pane(artifact_source)); local root = cx.session:surface(artifact_source, {root="main", depth=0, nodes=1}).main; local a = root.p.herd_artifacts; assert(a); '
artifact_current_config='[{"label":"Report","path":".scratch/report.md"},{"label":"Review","path":".scratch/review-*.md"},{"label":"Brief","path":".scratch/brief.md"}]'
artifact_wait() {
  local address count
  address=$(jq -Rn --arg value "$1" '$value'); count=$2
  wait_lua "${artifact_root}assert(root.p.herd_cursor == $address and a.address == $address and a.at ~= nil and not a.loading and not a.waiting and #a.matches == $count)"
}
artifact_initialize() {
  [ -n "${SHOOT_ARTIFACTS:-}" ]
  [ -f "$T/artifacts/.scratch/report.md" ]
  [ ! -d "$T/artifacts-missing/.scratch" ]
  check_lua "${probe}artifact_source = p; assert(root.p.herd_cursor == 't81')"
  artifact_wait t81 3
  local base
  base=$(jq -Rn --arg value "$T/artifacts/.scratch/" '$value')
  check_lua "${artifact_root}assert(not a.error and a.matches[1].path == $base .. 'report.md' and a.matches[2].path == $base .. 'review-001.md' and a.matches[3].path == $base .. 'brief.md')"
  [ "$(artifact_find_count)" -eq 1 ]
}
artifact_find_count() {
  if [ -f "$T/state/find.log" ]; then grep -c '^find ' "$T/state/find.log" || true; else printf '0\n'; fi
}
artifact_event() {
  local action
  action=$(jq -Rn --arg value "$1" '$value')
  check_lua "cx.layout:focus(artifact_source); cx.session:event(artifact_source, {ev='action', id='main', act=$action})"
}
artifact_no_documents() {
  check_lua "for _, pane in cx.session:panes() do assert(pane.kind ~= 'file', 'unexpected native file pane: ' .. tostring(pane.path)) end"
  [ ! -s "$T/state/actions.log" ]
}
artifact_buttons() {
  local reason
  reason=$(jq -Rn --arg value "${2:-}" '$value')
  wait_lua "local tree = cx.session:surface(artifact_source,{root='main',depth=16,nodes=2000}).main; local count = 0; local function visit(n) if string.match(n.id, 'artifact=%d+$') then count += 1; if $reason ~= '' then assert(string.find(tern.json.encode(n), $reason, 1, true)) end end; for _, child in n.c or {} do visit(child) end end; visit(tree); assert(count == $1, 'wrong artifact button count')"
}
artifact_open() {
  local path heading
  path=$(jq -Rn --arg value "$T/artifacts/$2" '$value')
  heading=$(jq -Rn --arg value "$3" '$value')
  artifact_event "artifact=$1"
  wait_lua "${artifact_root}local file; for _, pane in cx.session:panes() do if pane.kind == 'file' and pane.path == $path then file = pane.pane end end; assert(file and cx.session:focused() == file); local read = cx.session:read(file, {lines=40}); assert(read.kind == 'file' and read.path == $path and string.find(table.concat(read.lines, '\n'), $heading, 1, true)); artifact_document = file"
  check_lua "cx.layout:close(artifact_document); cx.layout:focus(artifact_source)"
  [ ! -s "$T/state/actions.log" ]
}
artifact_submit() {
  # Tern's native text-system selection addresses bytes of the prefilled JSON.
  # Specs in these cases are ASCII and compact-encoded by artifacts.config().
  ctl select-text 0 "${#artifact_current_config}" >/dev/null
  ctl type "$(jq -Rn --arg value "$1" '$value')" >/dev/null
  ctl key Enter >/dev/null
}
artifact_palette() {
  local palette_tree
  ctl palette 'Configure Herd artifacts' >/dev/null
  for _ in {1..30}; do
    pump
    palette_tree=$(ctl tree)
    # Input values are not result rows. Require the visible command label
    # outside native input/textarea nodes before pressing Enter exactly once.
    if jq -e '
      def label_text($input):
        ($input or (.tag? == "input") or (.tag? == "textarea")) as $inside
        | (if $inside then empty else .text? | select(type == "string") end),
          (.children[]? | label_text($inside));
      [.tree[]? | label_text(false)] | join(" ")
      | gsub("[[:space:]]+"; " ") | contains("Configure Herd artifacts")
    ' <<<"$palette_tree" >/dev/null; then
      ctl key Enter >/dev/null
      wait_text 'Artifact specs (JSON array; [] disables)'
      return
    fi
  done
  echo 'artifact palette command row did not become visible' >&2
  ctl tree >&2
  return 1
}
artifact_configure() {
  artifact_palette
  artifact_submit "$1"
}
artifact_config_saved() {
  local expected kv
  expected=$1; kv=${KVFILE:?}
  case "$kv" in "$T"/*) ;; *) echo 'artifact configuration escaped private KV' >&2; return 1 ;; esac
  wait_text 'Artifact links saved.'
  jq -e --argjson expected "$expected" '.artifact_specs == $expected' "$kv" >/dev/null
  artifact_current_config=$(jq -c . <<<"$expected")
}
artifact_wait_second() {
  local label
  label=$(jq -Rn --arg value "${2:-}" '$value')
  wait_lua "assert(artifact_second and cx.session:pane(artifact_second)); local root = cx.session:surface(artifact_second,{root='main',depth=0,nodes=1}).main; local a = root.p.herd_artifacts; assert(root.p.herd_cursor == 't81' and a.address == 't81' and a.at ~= nil and not a.loading and not a.waiting and #a.matches == $1 and #a.specs == $1); if $1 > 0 then assert(a.specs[1].label == $label and a.matches[1].label == $label and a.matches[1].path) end"
}
artifact_review_selection() {
  ctl key j >/dev/null
  artifact_wait t82 3
  ctl key Home >/dev/null
  artifact_wait t81 3
  local path
  path=$(jq -Rn --arg value "$T/artifacts/.scratch/$1" '$value')
  check_lua "${artifact_root}assert(not a.error and a.matches[2].path == $path)"
  artifact_open 2 ".scratch/$1" "$2"
}
artifact_wait_marker() {
  local marker=$1
  for _ in {1..40}; do
    [ ! -f "$marker" ] || return 0
    sleep 0.025
    ctl wait 50 >/dev/null
  done
  echo "artifact discovery barrier did not arrive: $marker" >&2
  return 1
}

case "$ACTION_CASE" in
  artifact-open)
    artifact_initialize
    artifact_open 1 .scratch/report.md '# Fictional cart report'
    artifact_open 2 .scratch/review-001.md '# Fictional review 001'
    artifact_open 3 .scratch/brief.md '# Fictional cart brief'
    [ "$(artifact_find_count)" -eq 1 ]
    artifact_no_documents
    echo 'artifacts: real Report/Brief and newest-mtime Review open as native file panes with exact private paths and content; only the selected cwd was scanned'
    ;;
  artifact-mtime)
    artifact_initialize
    review001=$T/artifacts/.scratch/review-001.md
    review999=$T/artifacts/.scratch/review-999.md
    second=$(date +%s)
    touch -d "@$second.000000001" "$review001"
    touch -d "@$second.000000002" "$review999"
    [ "$(stat -c %Y "$review001")" = "$second" ]
    [ "$(stat -c %Y "$review999")" = "$second" ]
    [[ "$(stat -c %y "$review001")" == *".000000001 "* ]]
    [[ "$(stat -c %y "$review999")" == *".000000002 "* ]]
    artifact_review_selection review-999.md '# Fictional review 999'
    touch -d "@$second.000000003" "$review001"
    [[ "$(stat -c %y "$review001")" == *".000000003 "* ]]
    artifact_review_selection review-001.md '# Fictional review 001'
    touch -r "$review001" "$review999"
    [ "$(stat -c %y "$review001")" = "$(stat -c %y "$review999")" ]
    artifact_review_selection review-001.md '# Fictional review 001'
    # GNU find emits signed floor-seconds and a positive fractional field.
    # Verify real filesystem support before exercising pre-epoch nanoseconds.
    if touch -d '@-0.500000001' "$review001" &&
       touch -d '@-0.500000000' "$review999" &&
       [ "$(stat -c %Y "$review001")" = -1 ] &&
       [ "$(stat -c %Y "$review999")" = -1 ] &&
       [[ "$(stat -c %y "$review001")" == *".499999999 "* ]] &&
       [[ "$(stat -c %y "$review999")" == *".500000000 "* ]]; then
      artifact_review_selection review-999.md '# Fictional review 999'
      echo 'artifact mtime: real negative-epoch timestamps differing by one nanosecond choose review-999'
    else
      echo 'artifact mtime: SKIP negative epoch; private filesystem/GNU touch cannot preserve the required timestamps'
    fi
    artifact_no_documents
    echo 'artifact mtime: actual current-epoch 1ns ordering selects review-999 then review-001; equal timestamps choose lexical review-001 through genuine rescans and native document reads'
    ;;
  artifact-missing-remote)
    artifact_initialize
    ctl key j >/dev/null
    artifact_wait t82 3
    check_lua "${artifact_root}assert(not a.error); for _, match in a.matches do assert(not match.path) end"
    artifact_buttons 3 'No matching local file'
    artifact_event artifact=1
    wait_text 'No current local artifact is available for this selection.'
    artifact_no_documents
    ctl key m >/dev/null
    wait_text 'Toasts muted.'
    ctl key End >/dev/null
    artifact_wait build-box/t83 0
    check_lua "${artifact_root}assert(a.error == 'Artifacts open for local hc terminals only.')"
    [ "$(artifact_find_count)" -eq 1 ]
    artifact_event artifact=1
    wait_text 'No current local artifact is available for this selection.'
    artifact_no_documents
    echo 'artifacts: missing files have no paths and cannot open; remote hc selection performs zero discovery and opens no document'
    ;;
  artifact-config)
    artifact_initialize
    check_lua "artifact_second = cx:new_block('herd.herd',nil,'beside'); assert(artifact_second)"
    artifact_wait_second 3 Report
    check_lua "${artifact_root}artifact_first_epoch = root.p.herd_selection; artifact_second_epoch = cx.session:surface(artifact_second,{root='main',depth=0,nodes=1}).main.p.herd_selection; artifact_config_focus = cx.session:focused()"
    custom='[{"label":"Checklist","path":".scratch/brief.md"}]'
    artifact_configure "$custom"
    artifact_config_saved "$custom"
    wait_lua "${artifact_root}local second = cx.session:surface(artifact_second,{root='main',depth=0,nodes=1}).main.p; assert(root.p.herd_selection > artifact_first_epoch and second.herd_selection > artifact_second_epoch and cx.session:focused() == artifact_config_focus)"
    artifact_wait t81 1
    artifact_wait_second 1 Checklist
    check_lua "${artifact_root}assert(a.matches[1].label == 'Checklist' and a.matches[1].path == $(jq -Rn --arg value "$T/artifacts/.scratch/brief.md" '$value'))"
    artifact_open 1 .scratch/brief.md '# Fictional cart brief'
    check_lua "${artifact_root}artifact_before_reload_at = a.at"
    ctl plugins fixtures >/dev/null
    wait_lua "${artifact_root}assert(a.specs[1].label == 'Checklist' and a.at and a.at > artifact_before_reload_at)"
    artifact_wait t81 1
    artifact_wait_second 1 Checklist
    check_lua "${artifact_root}assert(#a.specs == 1 and a.matches[1].label == 'Checklist')"
    artifact_configure '[{"label":"Escape","path":"../secret.md"}]'
    wait_text "Artifact paths must be relative, without '..'"
    jq -e --argjson expected "$custom" '.artifact_specs == $expected' "${KVFILE:?}" >/dev/null
    check_lua "${artifact_root}assert(#a.specs == 1 and a.specs[1].label == 'Checklist' and a.matches[1].label == 'Checklist')"
    artifact_wait_second 1 Checklist
    artifact_configure '{}'
    wait_text 'Artifact specs must be an array'
    jq -e --argjson expected "$custom" '.artifact_specs == $expected' "${KVFILE:?}" >/dev/null
    check_lua "${artifact_root}assert(#a.specs == 1 and a.specs[1].label == 'Checklist' and a.matches[1].label == 'Checklist')"
    artifact_wait_second 1 Checklist
    before_disable=$(artifact_find_count)
    check_lua "${artifact_root}artifact_first_epoch = root.p.herd_selection; artifact_second_epoch = cx.session:surface(artifact_second,{root='main',depth=0,nodes=1}).main.p.herd_selection; artifact_config_focus = cx.session:focused()"
    artifact_configure '[]'
    artifact_config_saved '[]'
    wait_lua "${artifact_root}local second = cx.session:surface(artifact_second,{root='main',depth=0,nodes=1}).main.p; assert(root.p.herd_selection > artifact_first_epoch and second.herd_selection > artifact_second_epoch and cx.session:focused() == artifact_config_focus)"
    artifact_wait t81 0
    artifact_wait_second 0
    check_lua "${artifact_root}assert(#a.specs == 0 and not a.error)"
    artifact_buttons 0
    artifact_event artifact=1
    wait_text 'No current local artifact is available for this selection.'
    artifact_no_documents
    [ "$(artifact_find_count)" -eq "$before_disable" ]
    check_lua "${artifact_root}artifact_before_reload_at = a.at"
    ctl plugins fixtures >/dev/null
    wait_lua "${artifact_root}assert(#a.specs == 0 and a.at and a.at > artifact_before_reload_at)"
    artifact_wait t81 0
    artifact_wait_second 0
    artifact_buttons 0
    [ "$(artifact_find_count)" -eq "$before_disable" ]
    artifact_no_documents
    echo 'artifacts: native global preferences refresh both live consoles without changing focus; custom config survives reload, invalid paths/{} preserve KV, and [] persists with zero discovery or opens'
    ;;
  artifact-config-closed)
    artifact_initialize
    check_lua 'cx.layout:close(artifact_source)'
    check_lua "for _, pane in cx.session:panes() do assert(pane.block ~= 'herd.herd' and pane.block ~= 'plugin.herd.herd', 'configuration must start without a Herd pane') end"
    artifact_palette
    custom='[{"label":"Summary","path":".scratch/report.md"}]'
    artifact_submit "$custom"
    artifact_config_saved "$custom"
    check_lua "for _, pane in cx.session:panes() do assert(pane.block ~= 'herd.herd' and pane.block ~= 'plugin.herd.herd', 'global configuration created a Herd pane') end"
    ctl plugins run plugin.herd.open >/dev/null
    wait_lua "${probe}artifact_source = p; local n = 0; for _, pane in cx.session:panes() do if pane.block == 'herd.herd' or pane.block == 'plugin.herd.herd' then n += 1 end end; assert(n == 1)"
    artifact_wait t81 1
    artifact_open 1 .scratch/report.md '# Fictional cart report'
    check_lua "${artifact_root}artifact_before_reload_at = a.at"
    ctl plugins fixtures >/dev/null
    wait_lua "${artifact_root}assert(a.specs[1].label == 'Summary' and a.at and a.at > artifact_before_reload_at)"
    artifact_wait t81 1
    if ctl tree | grep -Fq 'Artifact specs (JSON array; [] disables)'; then
      echo 'global artifact preferences prompt reopened after fixture reload' >&2
      return 1
    fi
    artifact_no_documents
    echo 'artifacts: global preferences save with zero Herd panes; a separately opened console uses Summary, and fixture reload does not reopen preferences'
    ;;
  artifact-stale)
    artifact_initialize
    ctl key j >/dev/null
    artifact_wait t82 3
    rm -f "$T/state/find.started" "$T/state/find.completed"
    touch "$T/state/find.hold"
    ctl key Home >/dev/null
    artifact_wait_marker "$T/state/find.started"
    check_lua "${artifact_root}assert(root.p.herd_cursor == 't81' and a.loading); artifact_held_epoch = root.p.herd_selection"
    ctl key j >/dev/null
    wait_cursor t82 artifact_source
    check_lua "${artifact_root}assert(a.address == 't82' and root.p.herd_selection > artifact_held_epoch); for _, match in a.matches do assert(not match.path) end"
    touch "$T/state/find.release"
    artifact_wait_marker "$T/state/find.completed"
    artifact_wait t82 3
    check_lua "${artifact_root}assert(not a.error); for _, match in a.matches do assert(not match.path) end"
    [ "$(artifact_find_count)" -eq 2 ]
    artifact_event artifact=1
    wait_text 'No current local artifact is available for this selection.'
    artifact_no_documents
    echo 'artifacts: a held real GNU find completes only after selection changes; its stale paths never replace the missing-file selection or open a document'
    ;;
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
  viewer-reuse)
    viewer_initialize
    viewer_new Enter viewer_read
    viewer_counts 1 0
    viewer_reuse
    viewer_reuse doubleclick
    viewer_counts 1 0
    # Attach is deliberately always writable and new, never a read-only reuse.
    viewer_new a viewer_write
    viewer_new a viewer_write_second
    wait_lua "assert(viewer_read ~= viewer_write and viewer_read ~= viewer_write_second and viewer_write ~= viewer_write_second); assert(cx.session:pane(viewer_read) and cx.session:pane(viewer_write) and cx.session:pane(viewer_write_second))"
    viewer_reuse
    viewer_counts 1 2
    echo 'viewer reuse: Enter/double-click focus one read-only pane; two writable Attach requests stay distinct; Watch never reuses writable Attach'
    ;;
  viewer-reload)
    viewer_initialize
    viewer_new Enter viewer_read
    viewer_counts 1 0
    ctl plugins fixtures >/dev/null
    wait_cursor t44 viewer_source
    viewer_reuse
    viewer_counts 1 0
    kv=${KVFILE:?shoot.sh must provide its validated private kv path}
    case "$kv" in "$T"/*) ;; *) echo 'viewer registry path escaped private run' >&2; exit 1 ;; esac
    jq -e '.viewer_registry.records | length > 0 and length <= 64' "$kv" >/dev/null
    echo 'viewer reload: real pane-id registry persists and Watch focuses the same live read-only pane without another attach'
    ;;
  viewer-closed)
    viewer_initialize
    viewer_new Enter viewer_read
    viewer_counts 1 0
    check_lua "viewer_closed = viewer_read; cx.layout:focus(viewer_source); cx.layout:close(viewer_closed)"
    wait_lua "assert(cx.session:pane(viewer_closed) == nil)"
    viewer_new Enter viewer_read
    wait_lua "assert(viewer_read ~= viewer_closed)"
    viewer_counts 2 0
    viewer_reuse
    viewer_counts 2 0
    echo 'viewer closed: closed pane is replaced exactly once, then reused; no terminal input or stop action'
    ;;
  viewer-replaced)
    viewer_initialize
    # An unregistered real terminal with a matching OSC title must not be
    # discovered by title heuristics and adopted as an hc Watch viewer.
    check_lua "viewer_decoy = cx.layout:new_tab({command=[=[printf '\\033]0;spam-192 t44\\007'; exec /bin/cat]=]}); assert(viewer_decoy)"
    wait_lua "local pane = cx.session:pane(viewer_decoy); assert(pane and string.find(pane.title,'spam-192 t44',1,true))"
    viewer_new Enter viewer_read
    viewer_counts 1 0
    wait_lua "assert(viewer_read ~= viewer_decoy and cx.session:pane(viewer_decoy))"
    document_json=$(jq -Rn --arg path "$T/crates/plugins/fixtures/herd/README.md" '$path')
    check_lua "viewer_replaced = viewer_read; cx.layout:focus(viewer_replaced); viewer_document = cx.docs:open($document_json,{how='replace'}); assert(cx.session:pane(viewer_document).kind == 'file')"
    # Native document replacement may retain the old terminal in the deck.
    # That is still a valid Watch viewer, so explicitly close it before
    # asserting replacement rather than demanding an unnecessary new split.
    check_lua "if viewer_replaced ~= viewer_document and cx.session:pane(viewer_replaced) then cx.layout:close(viewer_replaced) end"
    wait_lua "local old = cx.session:pane(viewer_replaced); assert(old == nil or (viewer_replaced == viewer_document and old.kind == 'file'))"
    viewer_new Enter viewer_read
    wait_lua "assert(viewer_read ~= viewer_document); local document = cx.session:pane(viewer_document); assert(document.kind == 'file' and document.path == $document_json)"
    viewer_counts 2 0
    viewer_reuse
    viewer_counts 2 0
    echo 'viewer identity: matching-title decoy ignored; a native file replacing the viewer is never reused as Watch'
    ;;
  viewer-missing)
    viewer_initialize
    viewer_new a viewer_write
    viewer_counts 0 1
    viewer_press d
    wait_text 'No Watch viewer for spam-192'
    wait_lua "${viewer_root}assert(#root.p.herd_requests == 0); local pane = cx.session:pane(viewer_write); assert(pane and not pane.floating and not pane.parked and pane.exited == nil)"
    viewer_counts 0 1
    check_lua "viewer_missing_count = #cx.session:panes()"
    viewer_press z
    wait_lua "${viewer_root}assert(#root.p.herd_requests == 0 and #cx.session:panes() == viewer_missing_count); local pane = cx.session:pane(viewer_write); assert(pane and not pane.floating and not pane.parked and pane.exited == nil)"
    viewer_counts 0 1
    viewer_new Enter viewer_read
    wait_lua "assert(viewer_read ~= viewer_write)"
    viewer_counts 1 1
    echo 'viewer missing: Dock/Park report no Watch instead of repurposing writable Attach; a subsequent Watch opens separately'
    ;;
  viewer-layout)
    viewer_initialize
    # Float may create the read-only viewer, but all later layout actions must
    # reuse that actual pane and keep its fake attach process alive.
    viewer_new p viewer_read
    wait_lua "${viewer_root}local pane = cx.session:pane(viewer_read); assert(#root.p.herd_requests == 0 and pane.floating and not pane.parked)"
    viewer_counts 1 0
    viewer_press d
    wait_lua "${viewer_root}local pane = cx.session:pane(viewer_read); assert(#root.p.herd_requests == 0 and not pane.floating and not pane.parked and pane.tab)"
    viewer_press z
    wait_lua "${viewer_root}local pane = cx.session:pane(viewer_read); assert(#root.p.herd_requests == 0 and pane.parked and pane.tab == nil and pane.exited == nil)"
    viewer_reuse
    viewer_counts 1 0
    viewer_event float
    wait_lua "${viewer_root}assert(#root.p.herd_requests == 0 and cx.session:pane(viewer_read).floating)"
    viewer_event dock
    wait_lua "${viewer_root}local pane = cx.session:pane(viewer_read); assert(#root.p.herd_requests == 0 and not pane.floating and not pane.parked)"
    viewer_event park
    wait_lua "${viewer_root}assert(#root.p.herd_requests == 0 and cx.session:pane(viewer_read).parked)"
    viewer_reuse
    viewer_counts 1 0
    echo 'viewer layout: native p/d/z and production Float/Dock/Park controls change real pane flags; Watch unparks the same running pane with one attach'
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
  activity-events)
    activity_baseline
    activity_phase 02
    wait_activity 3 3
    check_lua "${activity_root}local found = {}; for _, e in root.p.herd_activity do found[e.address] = e; assert(e.address ~= 't70' and e.address ~= 't74') end; assert(found.t71.status == 'blocked' and found.t73.status == 'done'); assert(found.t72.status == 'finished' and found.t72.exit_code == 7); assert(root.p.herd_cursor == 't71' and not root.p.herd_inbox)"
    rows=$(ctl tree | jq -r '.. | objects | select((.class? // "" | split(" ")) | index("sf-tbl-row")) | .. | objects | .text? // empty')
    [[ "$rows" = *b1-cart* && "$rows" != *b2-checkout* && "$rows" != *b0-summary* && "$rows" != *b4-images* ]]
    # h changes presentation, not observation arguments or ledger contents.
    ctl key h >/dev/null
    wait_text b2-checkout
    ctl key h >/dev/null
    wait_activity 3 3
    rows=$(ctl tree | jq -r '.. | objects | select((.class? // "" | split(" ")) | index("sf-tbl-row")) | .. | objects | .text? // empty')
    [[ "$rows" != *b2-checkout* ]]
    ctl key v >/dev/null
    wait_lua "${activity_root}assert(root.p.herd_inbox)"
    wait_activity 3 3
    wait_text 'Mark read'
    wait_text 'Clear'
    # Opening and closing the inbox do not acknowledge events.
    ctl key Escape >/dev/null
    wait_lua "${activity_root}assert(not root.p.herd_inbox)"
    activity_event activity
    wait_lua "${activity_root}assert(root.p.herd_inbox)"
    activity_event activity_back
    wait_lua "${activity_root}assert(not root.p.herd_inbox)"
    activity_phase 03
    wait_lua "${activity_root}assert(root.p.herd_summary.working == 1 and root.p.herd_summary.blocked == 0)"
    wait_activity 3 3
    activity_phase 04
    wait_activity 4 4
    # Add idle and error transitions through real list snapshots as well.
    jq '(.terminals[] | select(.address == "t71") | .status) = "working"' \
      "$T/fixture/phases/04.json" >"$T/fixture/phases/05.json"
    jq '(.terminals[] | select(.address == "t71") | .status) = "idle"' \
      "$T/fixture/phases/05.json" >"$T/fixture/phases/06.json"
    jq '(.terminals[] | select(.address == "t71") | .status) = "error"' \
      "$T/fixture/phases/06.json" >"$T/fixture/phases/07.json"
    activity_phase 05
    wait_lua "${activity_root}assert(root.p.herd_summary.working == 1)"
    wait_activity 4 4
    activity_phase 06
    wait_activity 5 5
    check_lua "${activity_root}assert(root.p.herd_activity[1].status == 'idle')"
    activity_phase 07
    wait_activity 6 6
    check_lua "${activity_root}assert(root.p.herd_activity[1].status == 'error')"
    # Unread keeps the native status segment present even with no work left.
    jq '.terminals = []' "$T/fixture/phases/07.json" >"$T/fixture/phases/08.json"
    activity_phase 08
    wait_lua "${activity_root}local s = root.p.herd_summary; assert(s.working == 0 and s.blocked == 0 and s.errors == 0 and s.unread == 6)"
    wait_activity 6 6
    wait_text '6 unread'
    wait_lua "local tree = cx.session:surface(activity_primary,{root='main',depth=6,nodes=500}).main; local found = false; local function visit(n) if string.sub(n.id,-16) == 'activity_control' then local encoded = tern.json.encode(n); assert(string.find(encoded,'Activity',1,true) and string.find(encoded,'\"6\"',1,true)); found = true end; for _, child in n.c or {} do visit(child) end end; visit(tree); assert(found, 'Activity head badge absent')"
    activity_event activity
    wait_lua "${activity_root}assert(root.p.herd_inbox)"
    activity_metadata
    activity_no_sweep
    echo 'activity events: baseline 0, blocked/hidden finish/done 3, repeat 3, done 4, idle 5, error 6; disappearance never guessed'
    ;;
  activity-persistence)
    activity_baseline
    activity_phase 02
    wait_activity 3 3
    activity_event activity
    wait_lua "${activity_root}assert(root.p.herd_inbox)"
    activity_event activity_read
    wait_activity 3 0
    check_lua "${activity_root}for _, e in root.p.herd_activity do assert(e.read) end; activity_old_ids = {}; for _, e in root.p.herd_activity do activity_old_ids[e.id] = true end"
    activity_phase 03
    wait_lua "${activity_root}assert(root.p.herd_summary.working == 1)"
    activity_phase 04
    wait_activity 4 1
    check_lua "${activity_root}activity_saved_ids = {}; for _, e in root.p.herd_activity do activity_saved_ids[e.id] = true; assert(e.read == (activity_old_ids[e.id] == true)) end"
    ctl plugins fixtures >/dev/null
    wait_activity 4 1
    check_lua "${activity_root}for _, e in root.p.herd_activity do assert(activity_saved_ids[e.id]); assert(e.read == (activity_old_ids[e.id] == true)) end"
    activity_metadata
    # Inspect only the ledger subtree: other plugin keys legitimately retain
    # scope state, and selected-terminal detail caches are not history.
    kv=${KVFILE:?shoot.sh must provide its validated private kv path}
    case "$kv" in "$T"/*) ;; *) echo 'validated kv path escaped the private run' >&2; exit 1 ;; esac
    [ -f "$kv" ]
    jq -e '.activity.events | length == 4' "$kv" >/dev/null
    jq -e '[.activity | .. | objects | keys[] | select(. == "cwd" or . == "argv" or . == "output" or . == "prompt" or . == "first_message")] | length == 0' "$kv" >/dev/null
    seen_before=$(jq -c '.activity.seen | map({address,state,status,runs}) | sort_by(.address)' "$kv")
    activity_event activity_clear
    wait_activity 0 0
    jq -e --argjson before "$seen_before" \
      '(.activity.seen | map({address,state,status,runs}) | sort_by(.address)) == $before' "$kv" >/dev/null
    # A nonzero working count is a list-completion barrier after reload,
    # unlike the initial/default zero count. Resuming adds no event.
    activity_phase 03
    wait_lua "${activity_root}assert(root.p.herd_summary.working == 1)"
    wait_activity 0 0
    ctl plugins fixtures >/dev/null
    wait_lua "${activity_root}assert(root.p.herd_summary.working == 1)"
    wait_activity 0 0
    activity_event refresh
    wait_lua "${activity_root}assert(root.p.herd_summary.working == 1)"
    wait_activity 0 0
    # Repeating a blocked/error snapshot after Clear must not reinterpret it
    # as a newly discovered attention transition. Reload makes nonzero
    # summary counts a completed-list barrier, not a stale prior render.
    activity_phase 02
    wait_activity 1 1
    wait_lua "${activity_root}assert(root.p.herd_summary.blocked == 1)"
    seen_before=$(jq -c '.activity.seen | map({address,state,status,runs}) | sort_by(.address)' "$kv")
    activity_event activity_clear
    wait_activity 0 0
    jq -e --argjson before "$seen_before" \
      '(.activity.seen | map({address,state,status,runs}) | sort_by(.address)) == $before' "$kv" >/dev/null
    ctl plugins fixtures >/dev/null
    wait_lua "${activity_root}assert(root.p.herd_summary.blocked == 1)"
    wait_activity 0 0
    jq '(.terminals[] | select(.address == "t71") | .status) = "error"' \
      "$T/fixture/phases/02.json" >"$T/fixture/phases/09.json"
    activity_phase 09
    wait_activity 1 1
    wait_lua "${activity_root}assert(root.p.herd_summary.errors == 1)"
    seen_before=$(jq -c '.activity.seen | map({address,state,status,runs}) | sort_by(.address)' "$kv")
    activity_event activity_clear
    wait_activity 0 0
    jq -e --argjson before "$seen_before" \
      '(.activity.seen | map({address,state,status,runs}) | sort_by(.address)) == $before' "$kv" >/dev/null
    ctl plugins fixtures >/dev/null
    wait_lua "${activity_root}assert(root.p.herd_summary.errors == 1)"
    wait_activity 0 0
    activity_no_sweep
    echo 'activity persistence: explicit read, new unread, IDs/read markers restored; clear survives reload and repeated observation'
    ;;
  activity-shared-scopes)
    activity_baseline
    # The first observer is muted, but both consoles share one real ledger.
    activity_event mute
    check_lua "activity_second = cx:new_block('herd.herd',nil,'beside'); assert(activity_second)"
    wait_activity 0 0 activity_second
    wait_lua "local r = cx.session:surface(activity_second,{root='main',depth=0,nodes=1}).main.p; assert(r.herd_summary.working == 4)"
    activity_phase 02
    wait_activity 3 3
    wait_activity 3 3 activity_second
    wait_lua "${activity_root}assert(root.p.herd_summary.working == 0 and root.p.herd_summary.blocked == 1)"
    wait_lua "local r = cx.session:surface(activity_second,{root='main',depth=0,nodes=1}).main.p; assert(r.herd_summary.working == 0 and r.herd_summary.blocked == 1)"
    check_lua "${activity_root}local other = cx.session:surface(activity_second,{root='main',depth=0,nodes=1}).main.p; for i, e in root.p.herd_activity do assert(other.herd_activity[i].id == e.id) end"
    # Every observer processes the same snapshot without adding duplicates.
    activity_event refresh activity_second
    wait_activity 3 3 activity_second
    # t71's cached get knows run=activity, even though that scope has no list
    # dataset. This tests association, not invented complete run history.
    activity_event 'herd_scope="activity"' activity_second
    wait_activity 1 1 activity_second
    wait_lua "local r = cx.session:surface(activity_second,{root='main',depth=0,nodes=1}).main.p; assert(r.herd_scope == 'activity' and r.herd_activity[1].address == 't71')"
    # Scoped list observations add t72 membership without a per-row get.
    activity_event 'herd_scope="cart"' activity_second
    wait_activity 2 2 activity_second
    activity_event activity_read activity_second
    wait_activity 2 0 activity_second
    wait_activity 3 1
    activity_event 'herd_scope="checkout"' activity_second
    wait_activity 1 1 activity_second
    wait_lua "local r = cx.session:surface(activity_second,{root='main',depth=0,nodes=1}).main.p; assert(r.herd_scope == 'checkout' and r.herd_activity[1].address == 't73')"
    activity_event activity_clear activity_second
    wait_activity 0 0 activity_second
    wait_activity 2 0
    activity_event 'herd_scope="missing"' activity_second
    wait_activity 0 0 activity_second
    activity_event 'herd_scope=""' activity_second
    wait_activity 2 0 activity_second
    activity_no_sweep '^get (t71|t73) --json$'
    echo 'activity shared scopes: muted observation persists; two consoles dedupe/sync; cached get and scoped membership; scoped read/clear do not affect other events'
    ;;
  activity-scope-order)
    activity_baseline
    check_lua "activity_second = cx:new_block('herd.herd',nil,'beside'); assert(activity_second)"
    wait_activity 0 0 activity_second
    wait_lua "local r = cx.session:surface(activity_second,{root='main',depth=0,nodes=1}).main.p; assert(r.herd_summary.working == 4)"
    # Capture one genuine fake-hc scoped reply before any All response can
    # observe the finish. Keep All on phase 01 until the capture marker exists.
    cp "$T/bin/hc" "$T/bin/hc-ready"
    {
      printf '#!/bin/sh\n'
      printf 'case "$*" in\n'
      printf '  "ls --json --all --label run=cart")\n'
      printf '    "%s" "$@" >"%s" || exit "$?"\n' "$T/bin/hc-ready" "$T/state/scoped.reply"
      printf '    : >"%s"\n' "$T/state/scoped.captured"
      printf '    n=0\n'
      printf '    while [ ! -e "%s" ]; do\n' "$T/state/scoped.release"
      printf '      if [ "$n" -ge 160 ]; then echo "scoped reply barrier exceeded 8 seconds" >&2; exit 124; fi\n'
      printf '      n=$((n + 1)); sleep 0.05\n'
      printf '    done\n'
      printf '    cat "%s"; exit 0 ;;\n' "$T/state/scoped.reply"
      printf 'esac\n'
      printf 'exec "%s" "$@"\n' "$T/bin/hc-ready"
    } >"$T/bin/hc-next"
    chmod +x "$T/bin/hc-next"
    mv "$T/bin/hc-next" "$T/bin/hc"
    jq '.terminals |= map(select(.address == "t71" or .address == "t72"))' \
      "$T/fixture/phases/02.json" >"$T/fixture/scopes/cart/ls-all.next"
    mv "$T/fixture/scopes/cart/ls-all.next" "$T/fixture/scopes/cart/ls-all.json"
    activity_event 'herd_scope="cart"' activity_second
    captured=""
    for _ in {1..60}; do
      pump
      if [ -f "$T/state/scoped.captured" ]; then captured=1; break; fi
    done
    [ -n "$captured" ] || { echo 'older scoped list did not reach its private reply barrier' >&2; exit 1; }
    grep -q '^ls --json --all --label run=cart$' "$T/state/invocations.log"
    jq -e 'any(.terminals[]; .address == "t72" and .state == "finished" and .exit_code == 7)' \
      "$T/state/scoped.reply" >/dev/null
    activity_phase 02
    wait_activity 3 3
    # An All-only working terminal proves a later-started All response was
    # applied before the older scoped response is released. First seeing a
    # working terminal establishes a baseline; it cannot add an event.
    jq '.terminals += [{address:"t75",name:"b5-catalog",state:"live",status:"working",turn:1,agent:"codex",cwd:"/home/alex/code/shop/.worktrees/catalog",where:"shop / 1"}]' \
      "$T/fixture/phases/02.json" >"$T/fixture/phases/10.json"
    activity_phase 10
    wait_lua "${activity_root}assert(root.p.herd_summary.working == 1 and root.p.herd_summary.blocked == 1)"
    wait_activity 3 3
    check_lua "${activity_root}for _, e in root.p.herd_activity do if e.address == 't72' then assert(not table.find(e.runs,'cart')) end end"
    touch "$T/state/scoped.release"
    wait_activity 2 2 activity_second
    wait_lua "local r = cx.session:surface(activity_second,{root='main',depth=0,nodes=1}).main.p; assert(r.herd_scope == 'cart' and r.herd_summary.blocked == 1); local finish; for _, e in r.herd_activity do if e.address == 't72' then finish = e end end; assert(finish and finish.status == 'finished' and finish.exit_code == 7 and table.find(finish.runs,'cart'))"
    wait_activity 3 3
    activity_no_sweep
    echo 'activity scope order: older matching scoped reply associates a nonselected finish after newer All observation, without duplicate events or get'
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
