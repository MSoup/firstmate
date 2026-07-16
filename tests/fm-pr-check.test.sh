#!/usr/bin/env bash
# Tests for bin/fm-pr-check.sh's generated check.sh content semantics.
#
# The watcher's check contract: a state/<id>.check.sh prints one line iff
# firstmate should wake; silence keeps sleeping. fm-pr-check.sh must arm a
# poll that wakes firstmate on the two outcomes that require a supervisor act:
#   - ready-to-merge (OPEN + mergeStateStatus=CLEAN): the direct-PR + yolo
#     signal for firstmate to perform the merge itself.
#   - merged (state=MERGED): post-merge confirmation for teardown.
# Silence must cover every interim and not-ready state (pending UNSTABLE,
# blocked BLOCKED, behind BEHIND, dirty DIRTY, empty mergeStateStatus, etc.)
# so the watcher does not spam wakes while CI is in flight or the PR cannot be
# merged.
#
# Matrix:
#   (a) ready-to-merge: OPEN + CLEAN -> check.sh prints "ready-to-merge"
#   (b) merged: MERGED + any status -> check.sh prints "merged"
#   (c) interim UNSTABLE: OPEN + UNSTABLE -> silence
#   (d) blocked: OPEN + BLOCKED -> silence
#   (e) behind: OPEN + BEHIND -> silence
#   (f) dirty: OPEN + DIRTY -> silence
#   (g) empty mergeStateStatus: OPEN + (blank) -> silence
#   (h) check.sh content is regenerated each run, not appended
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PR_CHECK="$ROOT/bin/fm-pr-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-check-tests)
PR_URL="https://github.com/example/repo/pull/7"

# Build a sandbox: state dir + task meta + a fakebin gh that returns the named
# state/mergeStateStatus pair for `gh pr view --json state,mergeStateStatus`.
# Args: case_name pr_state merge_state_status. Echoes the case dir.
make_case() {
  local name=$1 pr_state=$2 merge_state=$3 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "kind=ship" \
    "mode=direct-PR"
  # gh mock: fm-pr-check.sh's generated check.sh calls
  # `gh pr view URL --json state,mergeStateStatus -q '.state + " " + .mergeStateStatus'`
  # and the real gh applies the -q jq filter, printing `<state> <mergeState>`.
  # This mock returns that final string directly so the check.sh case statement
  # sees the same input the real gh would produce. Empty mergeStateStatus yields
  # "OPEN " which matches none of the case patterns and correctly stays silent.
  cat > "$fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
    printf '%s %s\n' "$pr_state" "$merge_state"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/gh"
  printf '%s\n' "$case_dir"
}

run_pr_check() {
  local case_dir=$1
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" task-x1 "$PR_URL"
}

# Execute the generated check.sh under the same fakebin gh and echo its output.
# Args: case_dir
run_check_sh() {
  local case_dir=$1
  PATH="$case_dir/fakebin:$PATH" bash "$case_dir/state/task-x1.check.sh"
}

test_ready_to_merge_open_clean() {
  local case_dir out
  case_dir=$(make_case ready-clean OPEN CLEAN)
  run_pr_check "$case_dir" >/dev/null
  [ -f "$case_dir/state/task-x1.check.sh" ] \
    || fail "ready-clean: fm-pr-check did not arm a check.sh"
  out=$(run_check_sh "$case_dir")
  [ "$out" = "ready-to-merge" ] \
    || fail "ready-clean: expected 'ready-to-merge', got '$out'"
  pass "OPEN + CLEAN triggers ready-to-merge wake"
}

test_merged_any_status() {
  local case_dir out
  case_dir=$(make_case merged MERGED CLEAN)
  run_pr_check "$case_dir" >/dev/null
  out=$(run_check_sh "$case_dir")
  [ "$out" = "merged" ] \
    || fail "merged: expected 'merged', got '$out'"
  pass "MERGED state triggers merged confirmation wake"
}

test_interim_unstable_silent() {
  local case_dir out
  case_dir=$(make_case unstable OPEN UNSTABLE)
  run_pr_check "$case_dir" >/dev/null
  out=$(run_check_sh "$case_dir")
  [ -z "$out" ] \
    || fail "unstable: expected silence, got '$out'"
  pass "OPEN + UNSTABLE (pending checks) stays silent"
}

test_blocked_silent() {
  local case_dir out
  case_dir=$(make_case blocked OPEN BLOCKED)
  run_pr_check "$case_dir" >/dev/null
  out=$(run_check_sh "$case_dir")
  [ -z "$out" ] \
    || fail "blocked: expected silence, got '$out'"
  pass "OPEN + BLOCKED stays silent"
}

test_behind_silent() {
  local case_dir out
  case_dir=$(make_case behind OPEN BEHIND)
  run_pr_check "$case_dir" >/dev/null
  out=$(run_check_sh "$case_dir")
  [ -z "$out" ] \
    || fail "behind: expected silence, got '$out'"
  pass "OPEN + BEHIND stays silent"
}

test_dirty_silent() {
  local case_dir out
  case_dir=$(make_case dirty OPEN DIRTY)
  run_pr_check "$case_dir" >/dev/null
  out=$(run_check_sh "$case_dir")
  [ -z "$out" ] \
    || fail "dirty: expected silence, got '$out'"
  pass "OPEN + DIRTY stays silent"
}

test_empty_merge_state_silent() {
  local case_dir out
  case_dir=$(make_case empty-merge OPEN "")
  run_pr_check "$case_dir" >/dev/null
  out=$(run_check_sh "$case_dir")
  [ -z "$out" ] \
    || fail "empty-merge: expected silence, got '$out'"
  pass "OPEN with empty mergeStateStatus stays silent"
}

test_check_sh_regenerated_not_appended() {
  local case_dir lines
  case_dir=$(make_case regen OPEN CLEAN)
  run_pr_check "$case_dir" >/dev/null
  run_pr_check "$case_dir" >/dev/null
  lines=$(grep -c 'gh pr view' "$case_dir/state/task-x1.check.sh" || true)
  expect_code 1 "$lines" \
    "regen: second fm-pr-check run appended to check.sh instead of replacing it"
  pass "fm-pr-check regenerates check.sh on each run rather than appending"
}

test_ready_to_merge_open_clean
test_merged_any_status
test_interim_unstable_silent
test_blocked_silent
test_behind_silent
test_dirty_silent
test_empty_merge_state_silent
test_check_sh_regenerated_not_appended