#!/usr/bin/env bash
# End-to-end action checks with fake hc and shoot.sh's external-opener guard.
set -euo pipefail
TEST=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
run_case() {
  local cold_scope_drain=0
  [ "$1" != scope-open ] || cold_scope_drain=1
  ACTION_CASE=$1 SHOOT_SCOPE_OPEN_DRAIN=$cold_scope_drain \
    SHOOT_HOOK='source "$TEST/actions-hook.sh"' "$TEST/shoot.sh" "${2:-activation}"
}
for action in watch doubleclick attach send interrupt; do run_case "$action"; done
SHOOT_WORKTREE=1 run_case worktree
SHOOT_CONTENDER=1 run_case doubleclick
for action in watch-unfocused doubleclick-unfocused; do run_case "$action"; done
for action in arbitration abandoned reload expire; do
  SHOOT_NO_CONSUMER=1 run_case "$action"
done
for action in viewer-reuse viewer-reload viewer-closed viewer-replaced viewer-layout viewer-missing; do
  run_case "$action"
done
for action in scope-fixtures scope-discovery scope-ui scope-open scope-reload scope-confirm-send scope-confirm-interrupt scope-confirm-finished scope-detail scope-summary; do
  run_case "$action" scopes
done
SHOOT_NO_CONSUMER=1 run_case scope-pending scopes
for action in needs-cycle needs-filter needs-scopes needs-bindings needs-focus needs-parked needs-open needs-loading-scope needs-no-poll; do
  run_case "$action" scopes
done
for action in activity-events activity-persistence activity-shared-scopes activity-scope-order; do
  SHOOT_PHASED=1 run_case "$action" activity
done
# Both native shell recording and PATH interception must fail closed.
if SHOOT_HOOK='"$TERNFD" ctl --control "$SOCK" open-url external-test://not-handled' \
  "$TEST/shoot.sh" activation; then
  echo 'actions: FAIL: native system opener escaped the guard' >&2
  exit 1
fi
if SHOOT_HOOK='"$T/bin/xdg-open" https://example.invalid' "$TEST/shoot.sh" activation; then
  echo 'actions: FAIL: executable opener escaped the guard' >&2
  exit 1
fi
echo 'actions: all action, viewer, scope, needs-you navigation, activity, arbitration, expiry, reload and opener-guard checks passed'
