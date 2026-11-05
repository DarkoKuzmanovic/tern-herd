#!/usr/bin/env bash
# End-to-end action checks with fake hc and shoot.sh's external-opener guard.
set -euo pipefail
TEST=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
run_case() {
  ACTION_CASE=$1 SHOOT_HOOK='source "$TEST/actions-hook.sh"' "$TEST/shoot.sh" activation
}
for action in watch doubleclick attach send interrupt; do run_case "$action"; done
SHOOT_WORKTREE=1 run_case worktree
SHOOT_CONTENDER=1 run_case doubleclick
for action in arbitration abandoned reload expire; do
  SHOOT_NO_CONSUMER=1 run_case "$action"
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
echo 'actions: all action, arbitration, expiry, reload and opener-guard checks passed'
