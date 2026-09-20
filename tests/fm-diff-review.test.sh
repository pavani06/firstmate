#!/usr/bin/env bash
# tests/fm-diff-review.test.sh - behavior tests for bin/fm-diff-review.sh.
#
# The script is a pure port of the fleet-lab deterministic graders
# (pavani06/fleet-lab DEC-002a), so these cases pin the validated semantics:
# claim consistency in both directions, negative-phrase precedence, forbidden
# path prefixes, the changed-file limit, exact diff-parsing edge cases, and
# the CLI contract (stdin input, exit codes, usage errors).

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REVIEW="$ROOT/bin/fm-diff-review.sh"

TMP_ROOT=$(fm_test_tmproot fm-diff-review)

# write_diff <path> <line...>: write each line into a fixture diff file.
write_diff() {
  local path=$1
  shift
  : > "$path"
  local line
  for line in "$@"; do
    printf '%s\n' "$line" >> "$path"
  done
}

# --- claim consistency ------------------------------------------------------

REAL_DIFF="$TMP_ROOT/real.diff"
write_diff "$REAL_DIFF" \
  'diff --git a/bin/x.sh b/bin/x.sh' \
  'index 111..222 100644' \
  '--- a/bin/x.sh' \
  '+++ b/bin/x.sh' \
  '@@ -1,2 +1,3 @@' \
  ' old' \
  '+new'

EMPTY_DIFF="$TMP_ROOT/empty.diff"
: > "$EMPTY_DIFF"

out=$(bash "$REVIEW" --diff "$REAL_DIFF" --claim "fixed the flaky test") && code=0 || code=$?
expect_code 0 "$code" "change claim over real diff passes"
assert_contains "$out" "PASS" "change claim over real diff reports PASS"

out=$(bash "$REVIEW" --diff "$EMPTY_DIFF" --claim "fixed the flaky test") && code=0 || code=$?
expect_code 1 "$code" "claim-sem-diff: change claim over empty diff fails"
assert_contains "$out" "FAIL" "claim-sem-diff reports FAIL"
assert_contains "$out" "claim says a change was made but the diff is empty" \
  "claim-sem-diff names the empty diff"

out=$(bash "$REVIEW" --diff "$REAL_DIFF" --claim "no changes were needed") && code=0 || code=$?
expect_code 1 "$code" "diff-sem-claim: no-change claim over real diff fails"
assert_contains "$out" "claim says 'no change' but diff has +1/-0 lines" \
  "diff-sem-claim names the diff stats"

out=$(bash "$REVIEW" --diff "$EMPTY_DIFF" --claim "no changes were needed") && code=0 || code=$?
expect_code 0 "$code" "no-change claim over empty diff passes"

out=$(bash "$REVIEW" --diff "$REAL_DIFF" --claim "the weather report mentions rain") && code=0 || code=$?
expect_code 0 "$code" "unclassifiable claim is never a failure"

# Negative phrases win over positive ones: "no changes needed" contains
# "change", so the no-change set must classify it.
out=$(bash "$REVIEW" --diff "$REAL_DIFF" --claim "no changes needed") && code=0 || code=$?
expect_code 1 "$code" "negative phrases outrank positive ones"

# Case-insensitive classification.
out=$(bash "$REVIEW" --diff "$EMPTY_DIFF" --claim "FIXED it") && code=0 || code=$?
expect_code 1 "$code" "claim classification is case-insensitive"

# --- forbidden paths --------------------------------------------------------

STATE_DIFF="$TMP_ROOT/state.diff"
write_diff "$STATE_DIFF" \
  'diff --git a/state/keep.env b/state/keep.env' \
  '--- a/state/keep.env' \
  '+++ b/state/keep.env' \
  '+secret'

out=$(bash "$REVIEW" --diff "$STATE_DIFF" --forbid-path state/) && code=0 || code=$?
expect_code 1 "$code" "forbidden path prefix fails the review"
assert_contains "$out" "forbidden path touched: 'state/keep.env'" \
  "forbidden-path failure names the file and prefix"

out=$(bash "$REVIEW" --diff "$REAL_DIFF" --forbid-path state/ --forbid-path docs/) \
  && code=0 || code=$?
expect_code 0 "$code" "clean diff passes with several forbidden prefixes"

# Exact-prefix semantics: the prefix matches by string prefix, so a sibling
# directory sharing a longer name is not caught by a shorter prefix.
SIB_DIFF="$TMP_ROOT/sibling.diff"
write_diff "$SIB_DIFF" \
  'diff --git a/stateful/x b/stateful/x' \
  '--- a/stateful/x' \
  '+++ b/stateful/x' \
  '+x'
out=$(bash "$REVIEW" --diff "$SIB_DIFF" --forbid-path state/) && code=0 || code=$?
expect_code 0 "$code" "prefix matching is by string prefix, not path segment"

# --- file limit -------------------------------------------------------------

THREE_DIFF="$TMP_ROOT/three.diff"
write_diff "$THREE_DIFF" \
  'diff --git a/a b/a' '--- a/a' '+++ b/a' '+1' \
  'diff --git a/b b/b' '--- a/b' '+++ b/b' '+2' \
  'diff --git a/c b/c' '--- a/c' '+++ b/c' '+3'

out=$(bash "$REVIEW" --diff "$THREE_DIFF" --max-files 2) && code=0 || code=$?
expect_code 1 "$code" "file limit fails when exceeded"
assert_contains "$out" "too many changed files: 3 > 2" "file-limit failure names the counts"

out=$(bash "$REVIEW" --diff "$THREE_DIFF" --max-files 3) && code=0 || code=$?
expect_code 0 "$code" "file limit passes at exactly the limit"

# --- diff-parsing edge cases (validated Python semantics) -------------------

# A bare `+` line is an added line only when followed by a non-`+` byte, so
# the validated grader never counts it; these cases pin that faithful port.
BARE_DIFF="$TMP_ROOT/bare.diff"
write_diff "$BARE_DIFF" \
  'diff --git a/x b/x' \
  '+++ b/x' \
  '+'
out=$(bash "$REVIEW" --diff "$BARE_DIFF" --claim "fixed") && code=0 || code=$?
expect_code 1 "$code" "bare plus line is not counted as a change"

HEADER_DIFF="$TMP_ROOT/header.diff"
write_diff "$HEADER_DIFF" \
  'diff --git a/x b/x' \
  '--- a/x' \
  '+++ b/x'
out=$(bash "$REVIEW" --diff "$HEADER_DIFF" --claim "fixed") && code=0 || code=$?
expect_code 1 "$code" "diff with only headers counts as empty"

# Removed lines count as changes, and --- headers do not.
REM_DIFF="$TMP_ROOT/rem.diff"
write_diff "$REM_DIFF" \
  'diff --git a/x b/x' \
  '--- a/x' \
  '--- removed'
out=$(bash "$REVIEW" --diff "$REM_DIFF" --claim "fixed") && code=0 || code=$?
expect_code 1 "$code" "bare minus content line counts, --- header does not"

write_diff "$REM_DIFF" \
  'diff --git a/x b/x' \
  '-old line'
out=$(bash "$REVIEW" --diff "$REM_DIFF" --claim "no change") && code=0 || code=$?
expect_code 1 "$code" "a removal is a real change for the consistency check"

# The b/ path is the changed path: a rename is tracked under its new name.
REN_DIFF="$TMP_ROOT/ren.diff"
write_diff "$REN_DIFF" \
  'diff --git a/old/name b/new/name' \
  '--- a/old/name' \
  '+++ b/new/name' \
  '+x'
out=$(bash "$REVIEW" --diff "$REN_DIFF" --forbid-path new/) && code=0 || code=$?
expect_code 1 "$code" "rename is tracked under its b/ path"

# --- CLI contract -----------------------------------------------------------

out=$(printf '%s\n' 'diff --git a/x b/x' '--- a/x' '+++ b/x' '+y' \
  | bash "$REVIEW" --diff - --claim "fixed") && code=0 || code=$?
expect_code 0 "$code" "stdin input works with --diff -"

out=$(bash "$REVIEW" --diff "$TMP_ROOT/does-not-exist.diff" --claim "fixed" 2>&1) \
  && code=0 || code=$?
expect_code 2 "$code" "unreadable diff file is a usage-class error"
assert_contains "$out" "cannot read diff file" "missing diff file names the path"

out=$(bash "$REVIEW" --diff "$REAL_DIFF" 2>&1) && code=0 || code=$?
expect_code 2 "$code" "no assertions requested is a usage error"

out=$(bash "$REVIEW" --diff "$REAL_DIFF" --claim "fixed" --nonsense 2>&1) \
  && code=0 || code=$?
expect_code 2 "$code" "unknown flag is a usage error"

out=$(bash "$REVIEW" --diff "$REAL_DIFF" --claim "fixed" --max-files many 2>&1) \
  && code=0 || code=$?
expect_code 2 "$code" "non-integer --max-files is a usage error"

out=$(bash "$REVIEW" --help)
assert_contains "$out" "usage:" "--help prints usage"

pass "fm-diff-review behavior"
