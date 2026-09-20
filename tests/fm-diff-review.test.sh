#!/usr/bin/env bash
# tests/fm-diff-review.test.sh - behavior tests for bin/fm-diff-review.sh.
#
# The script ports the fleet-lab deterministic graders (pavani06/fleet-lab
# DEC-002a), so these cases pin the validated semantics: claim consistency in
# both directions, negative-phrase precedence, word-boundary classification,
# forbidden path prefixes, the changed-file limit, exact diff-parsing edge
# cases, the line-anchored coverage skeleton, and the CLI contract (stdin
# input, exit codes, usage errors).

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

# Classification matches whole words, so a change verb embedded in an unrelated
# word is not a change claim: the layer's value rests on zero false positives.
for claim in \
  "the upstream ticket is still unresolved" \
  "investigated the prefix parser only" \
  "audited the dispatch table"; do
  out=$(bash "$REVIEW" --diff "$EMPTY_DIFF" --claim "$claim") && code=0 || code=$?
  expect_code 0 "$code" "embedded verb is not a change claim: $claim"
done

# An explicit negation classifies the claim even when a positive word appears
# in it, including with a modifier between the negation and its noun.
out=$(bash "$REVIEW" --diff "$EMPTY_DIFF" \
  --claim "checked the dispatch table; no code change was warranted") \
  && code=0 || code=$?
expect_code 0 "$code" "negated change claim over empty diff passes"

out=$(bash "$REVIEW" --diff "$REAL_DIFF" \
  --claim "checked the dispatch table; no code change was warranted") \
  && code=0 || code=$?
expect_code 1 "$code" "negated change claim over real diff still fails"

# Inflections of a classified stem are classified too.
for claim in "fixing the parser" "removes the stale entry" "renamed the flag"; do
  out=$(bash "$REVIEW" --diff "$EMPTY_DIFF" --claim "$claim") && code=0 || code=$?
  expect_code 1 "$code" "inflected change verb is a change claim: $claim"
done

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

# --- line-anchored coverage skeleton ----------------------------------------

# Every hunk of the diff is enumerated with its file and @@ line ranges, so a
# reviewing agent receives the whole line-anchored surface it has to cover.
HUNKS_DIFF="$TMP_ROOT/hunks.diff"
write_diff "$HUNKS_DIFF" \
  'diff --git a/bin/one.sh b/bin/one.sh' \
  '--- a/bin/one.sh' \
  '+++ b/bin/one.sh' \
  '@@ -1,2 +1,3 @@ func_a()' \
  ' ctx' \
  '+added' \
  '@@ -40,6 +41,6 @@' \
  '-gone' \
  '+back' \
  'diff --git a/docs/two.md b/docs/two.md' \
  '--- a/docs/two.md' \
  '+++ b/docs/two.md' \
  '@@ -7 +7,2 @@' \
  '+line'

out=$(bash "$REVIEW" --diff "$HUNKS_DIFF" --max-files 5) && code=0 || code=$?
expect_code 0 "$code" "coverage skeleton run passes its assertion"
assert_contains "$out" "COVERAGE (hunks=3)" "skeleton counts every hunk"
assert_contains "$out" "bin/one.sh @@ -1,2 +1,3 @@" "skeleton anchors the first hunk to its file"
assert_contains "$out" "bin/one.sh @@ -40,6 +41,6 @@" "skeleton anchors the second hunk to its file"
assert_contains "$out" "docs/two.md @@ -7 +7,2 @@" "skeleton anchors a countless range to its file"

# Independent check that no hunk of the fixture is missing from the skeleton.
missing=''
while IFS= read -r hunk; do
  ranges=${hunk#'@@ '}
  ranges=${ranges%%' @@'*}
  case "$out" in
    *"@@ $ranges @@"*) ;;
    *) missing="$missing $ranges" ;;
  esac
done < <(grep '^@@ ' "$HUNKS_DIFF")
assert_equals '' "$missing" "every @@ hunk of the fixture appears in the skeleton"

# A diff with no hunks still reports its (empty) coverage.
out=$(bash "$REVIEW" --diff "$REAL_DIFF" --max-files 5) && code=0 || code=$?
assert_contains "$out" "COVERAGE (hunks=1)" "single-hunk diff reports one hunk"

out=$(bash "$REVIEW" --diff "$EMPTY_DIFF" --max-files 5) && code=0 || code=$?
assert_contains "$out" "COVERAGE (hunks=0)" "empty diff reports zero hunks"

# --- CLI contract -----------------------------------------------------------

out=$(printf '%s\n' 'diff --git a/x b/x' '--- a/x' '+++ b/x' '+y' \
  | bash "$REVIEW" --diff - --claim "fixed") && code=0 || code=$?
expect_code 0 "$code" "stdin input works with --diff -"

out=$(bash "$REVIEW" --diff "$TMP_ROOT/does-not-exist.diff" --claim "fixed" 2>&1) \
  && code=0 || code=$?
expect_code 2 "$code" "unreadable diff file is a usage-class error"
assert_contains "$out" "cannot read diff file" "missing diff file names the path"

# A directory is not a readable diff: reporting PASS over a diff the layer
# never read would be a fail-open verdict.
out=$(bash "$REVIEW" --diff "$TMP_ROOT" --forbid-path state/ 2>&1) && code=0 || code=$?
expect_code 2 "$code" "a directory as --diff is a read error, not a PASS"
assert_contains "$out" "cannot read diff file" "directory diff names the path"
assert_not_contains "$out" "PASS" "directory diff never reports PASS"

# An empty flag value must not silently disable the assertion it requested.
out=$(bash "$REVIEW" --diff "$STATE_DIFF" --forbid-path '' 2>&1) && code=0 || code=$?
expect_code 2 "$code" "empty --forbid-path value is a usage error"
assert_not_contains "$out" "PASS" "empty --forbid-path never reports PASS"

out=$(bash "$REVIEW" --diff "$STATE_DIFF" --claim '' 2>&1) && code=0 || code=$?
expect_code 2 "$code" "empty --claim value is a usage error"

out=$(bash "$REVIEW" --diff "$STATE_DIFF" --max-files '' 2>&1) && code=0 || code=$?
expect_code 2 "$code" "empty --max-files value is a usage error"

out=$(bash "$REVIEW" --diff '' --claim "fixed" 2>&1) && code=0 || code=$?
expect_code 2 "$code" "empty --diff value is a usage error"

# A final line without a trailing newline is still parsed.
out=$(printf 'diff --git a/x b/x\n+new' | bash "$REVIEW" --diff - --claim "fixed the bug") \
  && code=0 || code=$?
expect_code 0 "$code" "unterminated final line is counted"
assert_contains "$out" "PASS (files=1, +1/-0)" "unterminated final added line is counted"

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
