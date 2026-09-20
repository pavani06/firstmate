#!/usr/bin/env bash
# tests/fm-diff-assert.test.sh - behavior tests for bin/fm-diff-assert.sh.
#
# The script graduates the fleet-lab deterministic graders (pavani06/fleet-lab
# DEC-002a), whose evidence is 12/12 planted synthetic failures detected with 0
# false positives. These cases hold that property on this CLI: the lab's 12
# planted failures and 3 clean controls ported 1:1 to the typed claim
# interface, the claims that earlier prose-classifying versions of this script
# misread, the diff shapes that change files without +/- lines, the
# line-anchored coverage skeleton, and the CLI contract.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REVIEW="$ROOT/bin/fm-diff-assert.sh"

TMP_ROOT=$(fm_test_tmproot fm-diff-assert)

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

# --- the lab's synthetic corpus, ported 1:1 ---------------------------------
# Diffs and cases mirror experiments/duolingo-graders/suite.py: every planted
# failure must be detected, every clean control must pass.

cat > "$TMP_ROOT/greet.diff" <<'EOF'
diff --git a/src/greet.py b/src/greet.py
new file mode 100644
--- /dev/null
+++ b/src/greet.py
@@ -0,0 +1,3 @@
+def greet(name):
+    return f"hello {name}"
EOF

cat > "$TMP_ROOT/mod.diff" <<'EOF'
diff --git a/src/mod.py b/src/mod.py
--- a/src/mod.py
+++ b/src/mod.py
@@ -1,3 +1,5 @@
 def a():
     pass
+
+def b():
+    pass
EOF

cat > "$TMP_ROOT/debug.diff" <<'EOF'
diff --git a/src/worker.py b/src/worker.py
--- a/src/worker.py
+++ b/src/worker.py
@@ -1,3 +1,4 @@
 def run():
+    print("DEBUG: starting")
     return 0
EOF

cat > "$TMP_ROOT/secret.diff" <<'EOF'
diff --git a/src/config.py b/src/config.py
--- a/src/config.py
+++ b/src/config.py
@@ -1,2 +1,3 @@
+API_KEY = "sk-1234567890abcdef"
 SECRET = "placeholder"
EOF

cat > "$TMP_ROOT/three-files.diff" <<'EOF'
diff --git a/src/a.py b/src/a.py
--- a/src/a.py
+++ b/src/a.py
@@ -1 +1 @@
-old
+new
diff --git a/src/b.py b/src/b.py
--- a/src/b.py
+++ b/src/b.py
@@ -1 +1 @@
-old
+new
diff --git a/src/c.py b/src/c.py
--- a/src/c.py
+++ b/src/c.py
@@ -1 +1 @@
-old
+new
EOF

cat > "$TMP_ROOT/four-files.diff" <<'EOF'
diff --git a/1.py b/1.py
--- a/1.py
+++ b/1.py
@@ -1 +1 @@
-a
+b
diff --git a/2.py b/2.py
--- a/2.py
+++ b/2.py
@@ -1 +1 @@
-a
+b
diff --git a/3.py b/3.py
--- a/3.py
+++ b/3.py
@@ -1 +1 @@
-a
+b
diff --git a/4.py b/4.py
--- a/4.py
+++ b/4.py
@@ -1 +1 @@
-a
+b
EOF

cat > "$TMP_ROOT/src-and-docs.diff" <<'EOF'
diff --git a/src/util.py b/src/util.py
--- a/src/util.py
+++ b/src/util.py
@@ -1 +1 @@
-old
+new
diff --git a/docs/readme.md b/docs/readme.md
--- a/docs/readme.md
+++ b/docs/readme.md
@@ -1 +1 @@
-old
+new
EOF

cat > "$TMP_ROOT/src-a-and-sub.diff" <<'EOF'
diff --git a/src/a.py b/src/a.py
--- a/src/a.py
+++ b/src/a.py
@@ -1 +1 @@
-old
+new
diff --git a/src/sub/b.py b/src/sub/b.py
--- a/src/sub/b.py
+++ b/src/sub/b.py
@@ -1 +1 @@
-old
+new
EOF

EMPTY_DIFF="$TMP_ROOT/empty.diff"
: > "$EMPTY_DIFF"

# run_case <id> <expected-code> <args...>
run_case() {
  local id=$1 want=$2 code=0
  shift 2
  bash "$REVIEW" "$@" > /dev/null 2>&1 || code=$?
  expect_code "$want" "$code" "lab case $id"
}

# The 12 planted failures: 8 diff-assertion cases, 4 claim cases.
run_case da_require_missing 1 \
  --diff "$TMP_ROOT/greet.diff" --require 'def farewell'
run_case da_require_missing_multi 1 \
  --diff "$TMP_ROOT/mod.diff" --require 'def a' --require 'def c'
run_case da_exclude_present 1 \
  --diff "$TMP_ROOT/debug.diff" --exclude 'print("DEBUG'
run_case da_exclude_present_secret 1 \
  --diff "$TMP_ROOT/secret.diff" --exclude 'sk-'
run_case da_max_files_exceeded 1 \
  --diff "$TMP_ROOT/three-files.diff" --max-files 2
run_case da_max_files_exceeded_strict 1 \
  --diff "$TMP_ROOT/four-files.diff" --max-files 1
run_case da_path_violation 1 \
  --diff "$TMP_ROOT/src-and-docs.diff" --allow-path 'src/'
run_case da_path_violation_exact 1 \
  --diff "$TMP_ROOT/src-a-and-sub.diff" --allow-path 'src/a.py'
run_case noc_nochange_with_diff 1 \
  --diff "$TMP_ROOT/debug.diff" --claim no-change \
  --note 'No changes needed, the code is already correct.'
run_case noc_nochange_with_diff_variant 1 \
  --diff "$TMP_ROOT/greet.diff" --claim no-change --note 'nothing changed'
run_case noc_fixed_with_empty_diff 1 \
  --diff "$EMPTY_DIFF" --claim change --note 'Fixed the bug in the login handler.'
run_case noc_fixed_with_empty_diff_variant 1 \
  --diff "$EMPTY_DIFF" --claim change --note 'done - implemented the fix'

# The 3 clean controls: none of them may be flagged.
run_case ctl_da_clean 0 \
  --diff "$TMP_ROOT/greet.diff" --require 'def greet' --exclude 'DEBUG' \
  --max-files 1 --allow-path 'src/'
run_case ctl_noc_nochange_empty 0 \
  --diff "$EMPTY_DIFF" --claim no-change --note 'no changes needed'
run_case ctl_noc_change_with_diff 0 \
  --diff "$TMP_ROOT/greet.diff" --claim change --note 'fixed'

# Each failure names the assertion that produced it.
out=$(bash "$REVIEW" --diff "$TMP_ROOT/mod.diff" --require 'def c' 2>&1) && code=0 || code=$?
expect_code 1 "$code" "absent required substring fails"
assert_contains "$out" "required text on no added line: 'def c'" "missing --require names the substring"

out=$(bash "$REVIEW" --diff "$TMP_ROOT/secret.diff" --exclude 'sk-' 2>&1) && code=0 || code=$?
assert_contains "$out" "forbidden text on an added line: 'sk-'" "present --exclude names the substring"

out=$(bash "$REVIEW" --diff "$TMP_ROOT/src-and-docs.diff" --allow-path 'src/' 2>&1) \
  && code=0 || code=$?
assert_contains "$out" "changed file outside allowed paths: 'docs/readme.md'" \
  "--allow-path failure names the stray file"

out=$(bash "$REVIEW" --diff "$TMP_ROOT/three-files.diff" --max-files 2 2>&1) && code=0 || code=$?
assert_contains "$out" "too many changed files: 3 > 2" "file-limit failure names the counts"

# --- --require and --exclude read added lines only --------------------------

# A context line carries code the change did not introduce, so matching it
# would fail a diff for someone else's pre-existing text.
CONTEXT_DIFF="$TMP_ROOT/context.diff"
write_diff "$CONTEXT_DIFF" \
  'diff --git a/worker.py b/worker.py' \
  '--- a/worker.py' \
  '+++ b/worker.py' \
  '@@ -1,3 +1,3 @@' \
  ' def run():' \
  '     print("DEBUG: legacy trace")' \
  '-    return 0' \
  '+    return 1'

out=$(bash "$REVIEW" --diff "$CONTEXT_DIFF" --exclude 'print("DEBUG') && code=0 || code=$?
expect_code 0 "$code" "--exclude ignores an unchanged context line"

out=$(bash "$REVIEW" --diff "$CONTEXT_DIFF" --require 'return 0') && code=0 || code=$?
expect_code 1 "$code" "--require is not satisfied by a removed line"
assert_contains "$out" "required text on no added line: 'return 0'" \
  "removed-line --require failure names the substring"

out=$(bash "$REVIEW" --diff "$CONTEXT_DIFF" --require 'worker.py') && code=0 || code=$?
expect_code 1 "$code" "--require is not satisfied by a file header"

out=$(bash "$REVIEW" --diff "$CONTEXT_DIFF" --require 'return 1') && code=0 || code=$?
expect_code 0 "$code" "--require is satisfied by the added line"

out=$(bash "$REVIEW" --diff "$CONTEXT_DIFF" --exclude 'return 1') && code=0 || code=$?
expect_code 1 "$code" "--exclude trips on the added line"

# The hunk header is not searchable text either.
out=$(bash "$REVIEW" --diff "$CONTEXT_DIFF" --require '@@ -1,3') && code=0 || code=$?
expect_code 1 "$code" "--require is not satisfied by a hunk header"

# --- the typed claim carries no language ------------------------------------

REAL_DIFF="$TMP_ROOT/real.diff"
write_diff "$REAL_DIFF" \
  'diff --git a/bin/x.sh b/bin/x.sh' \
  'index 111..222 100644' \
  '--- a/bin/x.sh' \
  '+++ b/bin/x.sh' \
  '@@ -1,2 +1,3 @@' \
  ' old' \
  '+new'

out=$(bash "$REVIEW" --diff "$REAL_DIFF" --claim change) && code=0 || code=$?
expect_code 0 "$code" "change claim over a real diff passes"
assert_contains "$out" "PASS (files=1, +1/-0)" "passing run reports the diff facts"

out=$(bash "$REVIEW" --diff "$EMPTY_DIFF" --claim change) && code=0 || code=$?
expect_code 1 "$code" "change claim over an empty diff fails"
assert_contains "$out" "claim is 'change' but the diff changes nothing" \
  "empty-diff failure names the claim"

out=$(bash "$REVIEW" --diff "$REAL_DIFF" --claim no-change) && code=0 || code=$?
expect_code 1 "$code" "no-change claim over a real diff fails"
assert_contains "$out" "claim is 'no-change' but the diff has +1/-0 lines" \
  "no-change failure names the diff stats"

out=$(bash "$REVIEW" --diff "$EMPTY_DIFF" --claim no-change) && code=0 || code=$?
expect_code 0 "$code" "no-change claim over an empty diff passes"

# Every claim that earlier prose-classifying versions of this script misread is
# now carried as an uninterpreted note, so none of them can produce a verdict.
NOTES_OVER_EMPTY=(
  'checked the dispatch table; no code change was warranted'
  'the upstream ticket is still unresolved'
  'investigated the prefix parser only'
  'done investigating; the logs looked fine'
  'the task is complete: the behaviour already matches the spec'
)
for note in "${NOTES_OVER_EMPTY[@]}"; do
  out=$(bash "$REVIEW" --diff "$EMPTY_DIFF" --claim no-change --note "$note") \
    && code=0 || code=$?
  expect_code 0 "$code" "note over empty diff is never classified: $note"
  assert_contains "$out" "NOTE: $note" "the note is reported verbatim: $note"
done

NOTES_OVER_REAL=(
  'refactor: extract helper, no functional changes'
  'renamed the flag; no behavior change'
  'fixed the crash; no API change'
  'added a guard, no other changes needed'
)
for note in "${NOTES_OVER_REAL[@]}"; do
  out=$(bash "$REVIEW" --diff "$REAL_DIFF" --claim change --note "$note") \
    && code=0 || code=$?
  expect_code 0 "$code" "note over real diff is never classified: $note"
done

# A note alone asserts nothing, so it cannot stand in for an assertion.
out=$(bash "$REVIEW" --diff "$REAL_DIFF" --note 'just a remark' 2>&1) && code=0 || code=$?
expect_code 2 "$code" "a note on its own is not an assertion"

# Only the two verdict tokens are accepted.
for bad in 'fixed the flaky test' 'no changes were needed' 'Change' 'nochange'; do
  out=$(bash "$REVIEW" --diff "$REAL_DIFF" --claim "$bad" 2>&1) && code=0 || code=$?
  expect_code 2 "$code" "free-text claim is a usage error: $bad"
  assert_contains "$out" "--claim must be exactly 'change' or 'no-change'" \
    "rejected claim explains the typed interface: $bad"
done

# --- diffs that change files without +/- lines ------------------------------

RENAME_DIFF="$TMP_ROOT/rename.diff"
write_diff "$RENAME_DIFF" \
  'diff --git a/old.txt b/new.txt' \
  'similarity index 100%' \
  'rename from old.txt' \
  'rename to new.txt'
out=$(bash "$REVIEW" --diff "$RENAME_DIFF" --claim change) && code=0 || code=$?
expect_code 0 "$code" "a pure rename is a change"
out=$(bash "$REVIEW" --diff "$RENAME_DIFF" --claim no-change) && code=0 || code=$?
expect_code 1 "$code" "a pure rename contradicts a no-change claim"
assert_contains "$out" "a created, deleted, renamed, copied, mode-changed or binary file" \
  "structural-only failure names what changed"

BINARY_DIFF="$TMP_ROOT/binary.diff"
write_diff "$BINARY_DIFF" \
  'diff --git a/img/logo.png b/img/logo.png' \
  'index 111..222 100644' \
  'Binary files a/img/logo.png and b/img/logo.png differ'
out=$(bash "$REVIEW" --diff "$BINARY_DIFF" --claim change) && code=0 || code=$?
expect_code 0 "$code" "a binary-only change is a change"
out=$(bash "$REVIEW" --diff "$BINARY_DIFF" --claim no-change) && code=0 || code=$?
expect_code 1 "$code" "a binary-only change contradicts a no-change claim"

MODE_DIFF="$TMP_ROOT/mode.diff"
write_diff "$MODE_DIFF" \
  'diff --git a/bin/run.sh b/bin/run.sh' \
  'old mode 100644' \
  'new mode 100755'
out=$(bash "$REVIEW" --diff "$MODE_DIFF" --claim change) && code=0 || code=$?
expect_code 0 "$code" "a mode-only change is a change"
out=$(bash "$REVIEW" --diff "$MODE_DIFF" --claim no-change) && code=0 || code=$?
expect_code 1 "$code" "a mode-only change contradicts a no-change claim"

# Creating or deleting a tracked file is a change even when it holds no lines.
NEWFILE_DIFF="$TMP_ROOT/newfile-empty.diff"
write_diff "$NEWFILE_DIFF" \
  'diff --git a/empty.gitkeep b/empty.gitkeep' \
  'new file mode 100644' \
  'index 0000000..e69de29'
out=$(bash "$REVIEW" --diff "$NEWFILE_DIFF" --claim change) && code=0 || code=$?
expect_code 0 "$code" "creating an empty tracked file is a change"
out=$(bash "$REVIEW" --diff "$NEWFILE_DIFF" --claim no-change) && code=0 || code=$?
expect_code 1 "$code" "creating an empty tracked file contradicts a no-change claim"

DELFILE_DIFF="$TMP_ROOT/delfile-empty.diff"
write_diff "$DELFILE_DIFF" \
  'diff --git a/empty.gitkeep b/empty.gitkeep' \
  'deleted file mode 100644' \
  'index e69de29..0000000'
out=$(bash "$REVIEW" --diff "$DELFILE_DIFF" --claim change) && code=0 || code=$?
expect_code 0 "$code" "deleting an empty tracked file is a change"
out=$(bash "$REVIEW" --diff "$DELFILE_DIFF" --claim no-change) && code=0 || code=$?
expect_code 1 "$code" "deleting an empty tracked file contradicts a no-change claim"

# --- content lines are classified by hunk state -----------------------------

# Outside a hunk body nothing is content, which is what excludes the ---/+++
# file headers and a stray marker no hunk introduced.
BARE_DIFF="$TMP_ROOT/bare.diff"
write_diff "$BARE_DIFF" \
  'diff --git a/x b/x' \
  '+++ b/x' \
  '+'
out=$(bash "$REVIEW" --diff "$BARE_DIFF" --claim change) && code=0 || code=$?
expect_code 1 "$code" "a bare plus outside any hunk is not counted as a change"

out=$(bash "$REVIEW" --diff "$BARE_DIFF" --require 'b/x') && code=0 || code=$?
expect_code 1 "$code" "a +++ header outside any hunk is not searchable content"

# Inside a hunk body every line starting with + or - is content, whatever
# follows the marker. A line whose own text begins with + or - is exactly how
# a diff of a diff looks, and the secret and debug-print guards must see it.
MARKER_DIFF="$TMP_ROOT/repeated-marker.diff"
write_diff "$MARKER_DIFF" \
  'diff --git a/t b/t' \
  '--- a/t' \
  '+++ b/t' \
  '@@ -1,2 +1,4 @@' \
  ' header' \
  '++ print("DEBUG: starting")' \
  '++API_KEY = "sk-1234567890abcdef"'

out=$(bash "$REVIEW" --diff "$MARKER_DIFF" --exclude 'sk-') && code=0 || code=$?
expect_code 1 "$code" "--exclude sees a secret on a line whose text starts with +"
assert_contains "$out" "forbidden text on an added line: 'sk-'" \
  "repeated-marker --exclude failure names the substring"

out=$(bash "$REVIEW" --diff "$MARKER_DIFF" --exclude 'print("DEBUG') && code=0 || code=$?
expect_code 1 "$code" "--exclude sees a debug print on a line whose text starts with +"

out=$(bash "$REVIEW" --diff "$MARKER_DIFF" --require 'API_KEY') && code=0 || code=$?
expect_code 0 "$code" "--require is satisfied by a line whose text starts with +"
assert_contains "$out" "PASS (files=1, +2/-0)" \
  "both repeated-marker lines are counted as added"

# A deleted markdown or YAML bullet lands as `-- item`; the removal count must
# report it rather than leaning on the hunk to rescue the verdict.
BULLET_DIFF="$TMP_ROOT/bullet.diff"
write_diff "$BULLET_DIFF" \
  'diff --git a/l.md b/l.md' \
  '--- a/l.md' \
  '+++ b/l.md' \
  '@@ -1,2 +1,1 @@' \
  ' intro' \
  '-- a yaml list item'
out=$(bash "$REVIEW" --diff "$BULLET_DIFF" --claim change) && code=0 || code=$?
expect_code 0 "$code" "deleting a bullet line is a change"
assert_contains "$out" "PASS (files=1, +0/-1)" "the deleted bullet is counted as removed"
out=$(bash "$REVIEW" --diff "$BULLET_DIFF" --claim no-change) && code=0 || code=$?
assert_contains "$out" "claim is 'no-change' but the diff has +0/-1 lines" \
  "the no-change failure names the real removal count"

# Git writes an @@ header only for a region it found different, so a hunk whose
# only edit is a blank line still changed the file. Both directions matter: the
# change claim must not be flagged, and the no-change claim must be.
BLANK_ADD_DIFF="$TMP_ROOT/blank-add.diff"
write_diff "$BLANK_ADD_DIFF" \
  'diff --git a/f.txt b/f.txt' \
  '--- a/f.txt' \
  '+++ b/f.txt' \
  '@@ -1,2 +1,3 @@' \
  ' a' \
  '+' \
  ' b'
out=$(bash "$REVIEW" --diff "$BLANK_ADD_DIFF" --claim change) && code=0 || code=$?
expect_code 0 "$code" "adding a blank line is a change"
out=$(bash "$REVIEW" --diff "$BLANK_ADD_DIFF" --claim no-change) && code=0 || code=$?
expect_code 1 "$code" "adding a blank line contradicts a no-change claim"
assert_contains "$out" "claim is 'no-change' but the diff has +1/-0 lines" \
  "the added blank line is counted"

BLANK_DEL_DIFF="$TMP_ROOT/blank-del.diff"
write_diff "$BLANK_DEL_DIFF" \
  'diff --git a/f.txt b/f.txt' \
  '--- a/f.txt' \
  '+++ b/f.txt' \
  '@@ -1,3 +1,2 @@' \
  ' a' \
  '-' \
  ' b'
out=$(bash "$REVIEW" --diff "$BLANK_DEL_DIFF" --claim change) && code=0 || code=$?
expect_code 0 "$code" "removing a blank line is a change"
out=$(bash "$REVIEW" --diff "$BLANK_DEL_DIFF" --claim no-change) && code=0 || code=$?
expect_code 1 "$code" "removing a blank line contradicts a no-change claim"

HEADER_DIFF="$TMP_ROOT/header.diff"
write_diff "$HEADER_DIFF" \
  'diff --git a/x b/x' \
  '--- a/x' \
  '+++ b/x'
out=$(bash "$REVIEW" --diff "$HEADER_DIFF" --claim change) && code=0 || code=$?
expect_code 1 "$code" "diff with only headers counts as empty"

# A `---` line is a header, never a removed content line.
REM_DIFF="$TMP_ROOT/rem.diff"
write_diff "$REM_DIFF" \
  'diff --git a/x b/x' \
  '--- a/x' \
  '--- removed'
out=$(bash "$REVIEW" --diff "$REM_DIFF" --claim change) && code=0 || code=$?
expect_code 1 "$code" "a --- line is never counted as a removal"

write_diff "$REM_DIFF" \
  'diff --git a/x b/x' \
  '--- a/x' \
  '+++ b/x' \
  '@@ -1 +0,0 @@' \
  '-old line'
out=$(bash "$REVIEW" --diff "$REM_DIFF" --claim no-change) && code=0 || code=$?
expect_code 1 "$code" "a removal is a real change for the consistency check"

# A hunk header with no content line under it still proves the region changed.
TRUNC_DIFF="$TMP_ROOT/truncated.diff"
write_diff "$TRUNC_DIFF" \
  'diff --git a/x b/x' \
  '--- a/x' \
  '+++ b/x' \
  '@@ -1,2 +1,3 @@'
out=$(bash "$REVIEW" --diff "$TRUNC_DIFF" --claim no-change) && code=0 || code=$?
expect_code 1 "$code" "a hunk with no content line still contradicts a no-change claim"
assert_contains "$out" "1 hunk(s) of changed lines" "hunk evidence names itself"

# The b/ path is the changed path: a rename is tracked under its new name.
REN_DIFF="$TMP_ROOT/ren.diff"
write_diff "$REN_DIFF" \
  'diff --git a/old/name b/new/name' \
  '--- a/old/name' \
  '+++ b/new/name' \
  '+x'
out=$(bash "$REVIEW" --diff "$REN_DIFF" --forbid-path new/) && code=0 || code=$?
expect_code 1 "$code" "rename is tracked under its b/ path"

# Prefix-less headers (git diff --no-prefix, or diff.noprefix=true) still
# populate the changed files, so the path and file-count assertions see them.
NOPREFIX_DIFF="$TMP_ROOT/noprefix.diff"
write_diff "$NOPREFIX_DIFF" \
  'diff --git state/secret.env state/secret.env' \
  '--- state/secret.env' \
  '+++ state/secret.env' \
  '@@ -1 +1,2 @@' \
  ' a' \
  '+b'
out=$(bash "$REVIEW" --diff "$NOPREFIX_DIFF" --forbid-path state/) && code=0 || code=$?
expect_code 1 "$code" "prefix-less header still trips --forbid-path"
assert_contains "$out" "forbidden path touched: 'state/secret.env'" \
  "prefix-less header yields the real path"
assert_contains "$out" "state/secret.env @@ -1 +1,2 @@" \
  "prefix-less header anchors its hunk to the real file"

out=$(bash "$REVIEW" --diff "$NOPREFIX_DIFF" --max-files 0) && code=0 || code=$?
expect_code 1 "$code" "prefix-less header is counted by --max-files"
assert_contains "$out" "too many changed files: 1 > 0" "prefix-less header counts one file"

out=$(bash "$REVIEW" --diff "$NOPREFIX_DIFF" --allow-path docs/) && code=0 || code=$?
expect_code 1 "$code" "prefix-less header is checked against --allow-path"

# Only the two spellings git writes name a path unambiguously. Any other
# prefix pair leaves the file unresolvable, and a path guard that cannot name
# its file must fail rather than clear it.
MNEMONIC_DIFF="$TMP_ROOT/mnemonic.diff"
write_diff "$MNEMONIC_DIFF" \
  'diff --git i/state/secret.env w/state/secret.env' \
  '--- i/state/secret.env' \
  '+++ w/state/secret.env' \
  '@@ -1 +1,2 @@' \
  ' a' \
  '+b'

out=$(bash "$REVIEW" --diff "$MNEMONIC_DIFF" --forbid-path state/) && code=0 || code=$?
expect_code 1 "$code" "a mnemonic-prefix header never clears --forbid-path"
assert_contains "$out" "changed file unresolvable from its header" \
  "unresolvable header is reported as such"
assert_not_contains "$out" "w/state/secret.env @@" \
  "an unresolvable header is never anchored to a prefixed path"

out=$(bash "$REVIEW" --diff "$MNEMONIC_DIFF" --allow-path state/) && code=0 || code=$?
expect_code 1 "$code" "a mnemonic-prefix header never clears --allow-path"
assert_not_contains "$out" "outside allowed paths: 'w/state/secret.env'" \
  "an unresolvable file is not mislabelled as a stray path"

# A prefix-less rename header names two different fields, but the stanza's own
# `rename to` line names the destination exactly, so the stanza resolves.
NOPREFIX_REN_DIFF="$TMP_ROOT/noprefix-rename.diff"
write_diff "$NOPREFIX_REN_DIFF" \
  'diff --git state/old.env state/new.env' \
  'similarity index 100%' \
  'rename from state/old.env' \
  'rename to state/new.env'
out=$(bash "$REVIEW" --diff "$NOPREFIX_REN_DIFF" --forbid-path state/) && code=0 || code=$?
expect_code 1 "$code" "a prefix-less rename never clears --forbid-path"
assert_contains "$out" "forbidden path touched: 'state/new.env'" \
  "the prefix-less rename destination is named, not refused"
assert_not_contains "$out" "unresolvable" \
  "a rename resolved from its own body is not an unresolvable header"

# An unresolvable file still counts toward the file limit, which needs no path.
out=$(bash "$REVIEW" --diff "$MNEMONIC_DIFF" --max-files 0) && code=0 || code=$?
expect_code 1 "$code" "an unresolvable file is still counted by --max-files"
out=$(bash "$REVIEW" --diff "$MNEMONIC_DIFF" --claim change) && code=0 || code=$?
expect_code 0 "$code" "an unresolvable header does not disturb the claim assertion"

# --- every changed file reaches the coverage skeleton -----------------------

# A rename, a binary rewrite and a mode change carry no hunk, so the coverage
# block has to name them under their markers or the reviewer is handed an
# empty surface over a diff that moved a secrets file.
HUNKLESS_REPO="$TMP_ROOT/hunkless-repo"
mkdir -p "$HUNKLESS_REPO/state" "$HUNKLESS_REPO/assets"
(
  cd "$HUNKLESS_REPO" || exit 1
  git init -q .
  git config user.email crew@example.test
  git config user.name crew
  printf 'secret\n' > state/secret.env
  printf 'PNGv1\000\001\002\n' > assets/logo.png
  printf 'echo hi\n' > run.sh
  git add -A
  git commit -qm init
  git mv state/secret.env state/moved.env
  printf 'PNGv2\000\003\004\n' > assets/logo.png
  chmod +x run.sh
  git add -A
  git diff --cached -M > "$TMP_ROOT/hunkless.diff"
) > /dev/null 2>&1

out=$(bash "$REVIEW" --diff "$TMP_ROOT/hunkless.diff" --claim change --max-files 5) \
  && code=0 || code=$?
expect_code 0 "$code" "a rename, binary and mode-only diff is a change"
assert_contains "$out" "COVERAGE (hunks=0)" "a hunkless diff reports no hunks"
assert_contains "$out" "state/secret.env -> state/moved.env - renamed, no hunk" \
  "the rename is listed under its marker with both paths"
assert_contains "$out" "assets/logo.png - binary, no hunk" \
  "the binary file is listed under its marker"
assert_contains "$out" "run.sh - mode change, no hunk" \
  "the mode-changed file is listed under its marker"

# Independent check that every path git named reaches the skeleton. The
# expected set comes from git's own name-status, not from re-deriving the
# header rule this script implements; a rename contributes both of its paths.
missing=''
while IFS= read -r path; do
  [ -n "$path" ] || continue
  case "$out" in
    *"$path"*) ;;
    *) missing="$missing $path" ;;
  esac
done < <(git -C "$HUNKLESS_REPO" diff --cached -M --name-status | cut -f2- | tr '\t' '\n')
assert_equals '' "$missing" "every changed path of the fixture appears in the skeleton"

# A file with hunks keeps its line ranges and gains no marker line.
out=$(bash "$REVIEW" --diff "$REAL_DIFF" --max-files 5) && code=0 || code=$?
assert_contains "$out" "bin/x.sh @@ -1,2 +1,3 @@" "a hunked file keeps its line range"
assert_not_contains "$out" "bin/x.sh - " "a hunked file gets no no-hunk entry"

# Creation and deletion name themselves too.
out=$(bash "$REVIEW" --diff "$NEWFILE_DIFF" --claim change) && code=0 || code=$?
assert_contains "$out" "empty.gitkeep - created, no hunk" "a created file names its marker"
out=$(bash "$REVIEW" --diff "$DELFILE_DIFF" --claim change) && code=0 || code=$?
assert_contains "$out" "empty.gitkeep - deleted, no hunk" "a deleted file names its marker"

# --- C-quoted header fields -------------------------------------------------

# Git C-quotes a path that needs escaping, independently per field. A file it
# quotes must resolve like any other, or one such file turns every path
# assertion in the diff into a false FAIL.
QUOTED_REPO="$TMP_ROOT/quoted-repo"
mkdir -p "$QUOTED_REPO"
(
  cd "$QUOTED_REPO" || exit 1
  git init -q .
  git config user.email crew@example.test
  git config user.name crew
  mkdir -p docs
  printf 'x\n' > "docs/$(printf 'caf\303\251')".md
  git add -A
  git diff --cached > "$TMP_ROOT/quoted.diff"
  git commit -qm init
  git mv "docs/$(printf 'caf\303\251')".md docs/plain.md
  git diff --cached -M > "$TMP_ROOT/quoted-rename.diff"
) > /dev/null 2>&1

out=$(bash "$REVIEW" --diff "$TMP_ROOT/quoted.diff" --allow-path docs/) && code=0 || code=$?
expect_code 0 "$code" "a C-quoted path resolves and satisfies --allow-path"
assert_not_contains "$out" "unresolvable" "a C-quoted header is not unresolvable"

out=$(bash "$REVIEW" --diff "$TMP_ROOT/quoted.diff" --forbid-path state/) && code=0 || code=$?
expect_code 0 "$code" "a C-quoted path outside the forbidden prefix does not fail"

out=$(bash "$REVIEW" --diff "$TMP_ROOT/quoted.diff" --forbid-path docs/) && code=0 || code=$?
expect_code 1 "$code" "a C-quoted path under the forbidden prefix still fails"

# Git quotes each field on its own, so a rename can quote only one side.
out=$(bash "$REVIEW" --diff "$TMP_ROOT/quoted-rename.diff" --allow-path docs/) \
  && code=0 || code=$?
expect_code 0 "$code" "a half-quoted rename header resolves to its b/ path"
assert_not_contains "$out" "unresolvable" "a half-quoted header is not unresolvable"

# The prefix-less spelling survives quoting too.
QUOTED_NOPREFIX="$TMP_ROOT/quoted-noprefix.diff"
write_diff "$QUOTED_NOPREFIX" \
  'diff --git "state/caf\303\251.env" "state/caf\303\251.env"' \
  '@@ -1 +1,2 @@' \
  ' a' \
  '+b'
out=$(bash "$REVIEW" --diff "$QUOTED_NOPREFIX" --forbid-path state/) && code=0 || code=$?
expect_code 1 "$code" "a quoted prefix-less header still trips --forbid-path"
assert_contains "$out" "forbidden path touched: 'state/caf\303\251.env'" \
  "the quoted prefix-less header yields its path"

# --- an ambiguous a/X b/Y header is unresolvable ----------------------------

# Git leaves a path containing spaces unquoted, so a directory ending in " b"
# puts a decoy " b/" ahead of the real split point. Nothing in the header says
# which occurrence splits it, so the path guard must not pick one and clear the
# file against a name it invented.
AMBIG_REPO="$TMP_ROOT/ambiguous-repo"
mkdir -p "$AMBIG_REPO"
(
  cd "$AMBIG_REPO" || exit 1
  git init -q .
  git config user.email crew@example.test
  git config user.name crew
  mkdir -p 'plan b' 'state b'
  printf 'notes\n' > 'plan b/notes.md'
  git add -A
  git commit -qm init
  git mv 'plan b/notes.md' 'state b/secret.env'
  git add -A
  git diff --cached -M > "$TMP_ROOT/ambiguous.diff"
) > /dev/null 2>&1

out=$(bash "$REVIEW" --diff "$TMP_ROOT/ambiguous.diff" --forbid-path 'state b/') \
  && code=0 || code=$?
expect_code 1 "$code" "an ambiguous rename header never clears --forbid-path"
assert_not_contains "$out" "notes.md b/state b/secret.env - " \
  "no invented path reaches the coverage skeleton"

out=$(bash "$REVIEW" --diff "$TMP_ROOT/ambiguous.diff" --allow-path 'state b/') \
  && code=0 || code=$?
expect_code 1 "$code" "an ambiguous rename header never clears --allow-path"
assert_not_contains "$out" "outside allowed paths: 'notes.md b/" \
  "an ambiguous header is not mislabelled as a stray path"

# An ambiguous header with no rename or copy line to name its file has nothing
# else to resolve it, so it stays refused rather than picking one split.
AMBIG_EDIT_DIFF="$TMP_ROOT/ambiguous-edit.diff"
write_diff "$AMBIG_EDIT_DIFF" \
  'diff --git a/plan b/notes.md b/plan b/notes.md' \
  '@@ -1 +1,2 @@' \
  ' n' \
  '+more'
out=$(bash "$REVIEW" --diff "$AMBIG_EDIT_DIFF" --forbid-path 'plan b/') && code=0 || code=$?
expect_code 1 "$code" "an ambiguous edit header never clears --forbid-path"
assert_contains "$out" "changed file unresolvable from its header" \
  "the ambiguous edit header is reported as unresolvable"
assert_not_contains "$out" "forbidden path touched: 'notes.md b/" \
  "no invented path reaches the forbidden-path guard"

# Headers carrying exactly one " b/" keep resolving, including the shapes that
# look ambiguous but are not.
ONE_SPLIT_DIFF="$TMP_ROOT/one-split.diff"
write_diff "$ONE_SPLIT_DIFF" \
  'diff --git a/b/x b/b/x' \
  '@@ -1 +1 @@' \
  '-o' \
  '+n'
out=$(bash "$REVIEW" --diff "$ONE_SPLIT_DIFF" --forbid-path 'b/') && code=0 || code=$?
expect_code 1 "$code" "a b/-named directory still resolves"
assert_contains "$out" "forbidden path touched: 'b/x'" "the b/ directory path is exact"

SPACE_DIFF="$TMP_ROOT/space-path.diff"
write_diff "$SPACE_DIFF" \
  'diff --git a/my file.txt b/my file.txt' \
  '@@ -1 +1 @@' \
  '-o' \
  '+n'
out=$(bash "$REVIEW" --diff "$SPACE_DIFF" --forbid-path 'my ') && code=0 || code=$?
expect_code 1 "$code" "an unquoted path with a space still resolves"
assert_contains "$out" "forbidden path touched: 'my file.txt'" "the spaced path is exact"

# The prefix-less spelling is matched by byte-identical fields, not by " b/",
# so a directory named "a b" keeps resolving there.
SPACE_NOPREFIX_DIFF="$TMP_ROOT/space-noprefix.diff"
write_diff "$SPACE_NOPREFIX_DIFF" \
  'diff --git a b/x a b/x' \
  '@@ -1 +1 @@' \
  '-o' \
  '+n'
out=$(bash "$REVIEW" --diff "$SPACE_NOPREFIX_DIFF" --forbid-path 'a b/') && code=0 || code=$?
expect_code 1 "$code" "a prefix-less header with a spaced directory still resolves"
assert_contains "$out" "forbidden path touched: 'a b/x'" "the prefix-less spaced path is exact"

# --- a rename touches both of its paths -------------------------------------

# Moving a file out of a guarded directory is a touch of that directory, so the
# source path has to reach the path assertions and the coverage skeleton.
RENAME_REPO="$TMP_ROOT/rename-repo"
mkdir -p "$RENAME_REPO"
(
  cd "$RENAME_REPO" || exit 1
  git init -q .
  git config user.email crew@example.test
  git config user.name crew
  mkdir -p state docs
  printf 'k=v\nl=2\nm=3\nn=4\no=5\n' > state/secret.env
  git add -A
  git commit -qm init
  git mv state/secret.env docs/secret.env
  git add -A
  git diff --cached -M > "$TMP_ROOT/rename-pure.diff"
  printf 'k=v\nl=2\nm=3\nn=4\no=CHANGED\n' > docs/secret.env
  git add -A
  git diff --cached -M > "$TMP_ROOT/rename-edited.diff"
) > /dev/null 2>&1

out=$(bash "$REVIEW" --diff "$TMP_ROOT/rename-pure.diff" --forbid-path state/) \
  && code=0 || code=$?
expect_code 1 "$code" "moving a file out of a forbidden prefix fails"
assert_contains "$out" "forbidden path touched: 'state/secret.env'" \
  "the rename source names the forbidden path"
assert_contains "$out" "state/secret.env -> docs/secret.env - renamed, no hunk" \
  "the coverage entry names both sides of the rename"

out=$(bash "$REVIEW" --diff "$TMP_ROOT/rename-pure.diff" --allow-path docs/) \
  && code=0 || code=$?
expect_code 1 "$code" "a rename out of the allowed prefixes fails"
assert_contains "$out" "outside allowed paths: 'state/secret.env'" \
  "the rename source is the file outside the allowed prefixes"

out=$(bash "$REVIEW" --diff "$TMP_ROOT/rename-pure.diff" --allow-path docs/ --allow-path state/) \
  && code=0 || code=$?
expect_code 0 "$code" "a rename passes when both of its sides are allowed"

# The destination still trips the guards on its own.
out=$(bash "$REVIEW" --diff "$TMP_ROOT/rename-pure.diff" --forbid-path docs/) \
  && code=0 || code=$?
expect_code 1 "$code" "the rename destination still trips --forbid-path"

# A rename carrying edits has hunks, so its source must reach coverage there too.
out=$(bash "$REVIEW" --diff "$TMP_ROOT/rename-edited.diff" --forbid-path state/) \
  && code=0 || code=$?
expect_code 1 "$code" "a rename with edits still fails --forbid-path on its source"
assert_contains "$out" "state/secret.env -> docs/secret.env @@" \
  "a hunk of a renamed file is anchored to both sides"

# The file limit still counts one changed file per diff --git stanza.
out=$(bash "$REVIEW" --diff "$TMP_ROOT/rename-pure.diff" --max-files 1) && code=0 || code=$?
expect_code 0 "$code" "a rename counts as one changed file"
assert_contains "$out" "PASS (files=1," "a rename reports one changed file"

# Git C-quotes a rename line whose path needs escaping, like any other field.
QUOTED_RENAME_DIFF="$TMP_ROOT/quoted-rename-src.diff"
write_diff "$QUOTED_RENAME_DIFF" \
  'diff --git "a/state/caf\303\251.env" "b/docs/caf\303\251.env"' \
  'similarity index 100%' \
  'rename from "state/caf\303\251.env"' \
  'rename to "docs/caf\303\251.env"'
out=$(bash "$REVIEW" --diff "$QUOTED_RENAME_DIFF" --forbid-path state/) && code=0 || code=$?
expect_code 1 "$code" "a C-quoted rename source still trips --forbid-path"
assert_contains "$out" "forbidden path touched: 'state/caf\303\251.env'" \
  "the C-quoted rename source is unquoted before matching"

# --- a copy changes its destination only ------------------------------------

# Git emits copy markers under --find-copies-harder or diff.renames=copies, a
# plain user-level setting that applies to the documented invocation. A copy
# creates a file, so it is a change; its source is read, not written, so only
# the destination is a changed file.
COPY_REPO="$TMP_ROOT/copy-repo"
mkdir -p "$COPY_REPO"
(
  cd "$COPY_REPO" || exit 1
  git init -q .
  git config user.email crew@example.test
  git config user.name crew
  mkdir -p state docs
  printf 'k=v\nl=2\nm=3\nn=4\no=5\n' > state/secret.env
  git add -A
  git commit -qm init
  cp state/secret.env docs/secret.env
  git add -A
  git -c diff.renames=copies diff --cached -C --find-copies-harder \
    > "$TMP_ROOT/copy-only.diff"
) > /dev/null 2>&1

out=$(bash "$REVIEW" --diff "$TMP_ROOT/copy-only.diff" --claim no-change) && code=0 || code=$?
expect_code 1 "$code" "a copy contradicts a no-change claim"
assert_contains "$out" "claim is 'no-change' but the diff has" \
  "the copy is reported as change evidence"

out=$(bash "$REVIEW" --diff "$TMP_ROOT/copy-only.diff" --claim change) && code=0 || code=$?
expect_code 0 "$code" "a copy satisfies a change claim"
assert_contains "$out" "state/secret.env -> docs/secret.env - copied, no hunk" \
  "the copy names both paths under its marker"

# Only the destination is a changed file: the source was read, not written.
out=$(bash "$REVIEW" --diff "$TMP_ROOT/copy-only.diff" --forbid-path docs/) && code=0 || code=$?
expect_code 1 "$code" "a copy into a forbidden prefix fails"
assert_contains "$out" "forbidden path touched: 'docs/secret.env'" \
  "the copy destination names the forbidden path"

out=$(bash "$REVIEW" --diff "$TMP_ROOT/copy-only.diff" --forbid-path state/) && code=0 || code=$?
expect_code 0 "$code" "a copy out of an untouched prefix does not fail"

out=$(bash "$REVIEW" --diff "$TMP_ROOT/copy-only.diff" --allow-path docs/) && code=0 || code=$?
expect_code 0 "$code" "a copy whose destination is allowed passes"

out=$(bash "$REVIEW" --diff "$TMP_ROOT/copy-only.diff" --max-files 1) && code=0 || code=$?
expect_code 0 "$code" "a copy counts as one changed file"

# --- a rename names its destination whatever the header spelling ------------

# diff.noprefix is an ordinary user-level git setting, and under it every
# rename header carries two differing fields. The stanza's own `rename to` line
# names the destination, so a clean diff must not be failed over its spelling.
NOPREFIX_REPO="$TMP_ROOT/noprefix-rename-repo"
mkdir -p "$NOPREFIX_REPO"
(
  cd "$NOPREFIX_REPO" || exit 1
  git init -q .
  git config user.email crew@example.test
  git config user.name crew
  git config diff.noprefix true
  mkdir -p src docs
  printf 'x\n' > src/one.txt
  printf 'k\n' > docs/keep.md
  git add -A
  git commit -qm init
  git mv src/one.txt src/two.txt
  printf 'k\ny\n' > docs/keep.md
  git add -A
  git diff --cached -M > "$TMP_ROOT/noprefix-rename-real.diff"
) > /dev/null 2>&1

out=$(bash "$REVIEW" --diff "$TMP_ROOT/noprefix-rename-real.diff" \
  --allow-path src/ --allow-path docs/) && code=0 || code=$?
expect_code 0 "$code" "a clean prefix-less diff with a rename passes --allow-path"
assert_not_contains "$out" "unresolvable" "no header in a clean rename diff is unresolvable"
assert_contains "$out" "src/one.txt -> src/two.txt - renamed, no hunk" \
  "the prefix-less rename names both of its paths"

out=$(bash "$REVIEW" --diff "$TMP_ROOT/noprefix-rename-real.diff" --forbid-path src/) \
  && code=0 || code=$?
expect_code 1 "$code" "the prefix-less rename still trips a forbidden prefix"

# An ambiguous " b/" header resolves the same way, from its own rename lines.
AMBIG_REN_DIFF="$TMP_ROOT/ambiguous-rename-body.diff"
write_diff "$AMBIG_REN_DIFF" \
  'diff --git a/plan b/notes.md b/state b/secret.env' \
  'similarity index 100%' \
  'rename from plan b/notes.md' \
  'rename to state b/secret.env'
out=$(bash "$REVIEW" --diff "$AMBIG_REN_DIFF" --forbid-path 'state b/') && code=0 || code=$?
expect_code 1 "$code" "an ambiguous rename header still trips the forbidden prefix"
assert_contains "$out" "forbidden path touched: 'state b/secret.env'" \
  "the ambiguous rename destination comes from its rename-to line"
assert_contains "$out" "plan b/notes.md -> state b/secret.env - renamed, no hunk" \
  "the ambiguous rename names both of its real paths"

out=$(bash "$REVIEW" --diff "$AMBIG_REN_DIFF" --allow-path 'plan b/' --allow-path 'state b/') \
  && code=0 || code=$?
expect_code 0 "$code" "an ambiguous rename passes when both of its real paths are allowed"

# A copy destination resolves from its own `copy to` line too.
NOPREFIX_COPY_DIFF="$TMP_ROOT/noprefix-copy.diff"
write_diff "$NOPREFIX_COPY_DIFF" \
  'diff --git state/keep.env docs/copy.env' \
  'similarity index 100%' \
  'copy from state/keep.env' \
  'copy to docs/copy.env'
out=$(bash "$REVIEW" --diff "$NOPREFIX_COPY_DIFF" --forbid-path docs/) && code=0 || code=$?
expect_code 1 "$code" "a prefix-less copy destination trips --forbid-path"
assert_contains "$out" "forbidden path touched: 'docs/copy.env'" \
  "the copy destination comes from its copy-to line"
out=$(bash "$REVIEW" --diff "$NOPREFIX_COPY_DIFF" --forbid-path state/) && code=0 || code=$?
expect_code 0 "$code" "a copy source stays out of the path assertions"

# A stanza with no rename/copy line to name it stays unresolvable.
out=$(bash "$REVIEW" --diff "$MNEMONIC_DIFF" --forbid-path state/) && code=0 || code=$?
expect_code 1 "$code" "a stanza with nothing to name it is still refused"
assert_contains "$out" "changed file unresolvable from its header" \
  "the unnameable stanza still reports itself unresolvable"

# --- a diff with no file header at all --------------------------------------

# A unified diff that git did not produce can carry hunks under no header. Its
# file cannot be named, so a path assertion must refuse it rather than clear it.
HEADERLESS_DIFF="$TMP_ROOT/headerless.diff"
write_diff "$HEADERLESS_DIFF" \
  '--- a/state/secret.env' \
  '+++ b/state/secret.env' \
  '@@ -1 +1,2 @@' \
  ' a' \
  '+SECRET=1'

out=$(bash "$REVIEW" --diff "$HEADERLESS_DIFF" --forbid-path state/) && code=0 || code=$?
expect_code 1 "$code" "a headerless diff never clears --forbid-path"
assert_contains "$out" "changed file unresolvable from its header" \
  "a headerless hunk is reported unresolvable"

out=$(bash "$REVIEW" --diff "$HEADERLESS_DIFF" --allow-path docs/) && code=0 || code=$?
expect_code 1 "$code" "a headerless diff never clears --allow-path"

out=$(bash "$REVIEW" --diff "$HEADERLESS_DIFF" --claim change) && code=0 || code=$?
expect_code 0 "$code" "a headerless diff still counts its content as a change"
assert_contains "$out" "(unknown file) @@ -1 +1,2 @@" \
  "a headerless hunk is anchored to a named placeholder, not a blank"

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

out=$(bash "$REVIEW" --diff "$REAL_DIFF" --max-files 5) && code=0 || code=$?
assert_contains "$out" "COVERAGE (hunks=1)" "single-hunk diff reports one hunk"

out=$(bash "$REVIEW" --diff "$EMPTY_DIFF" --max-files 5) && code=0 || code=$?
assert_contains "$out" "COVERAGE (hunks=0)" "empty diff reports zero hunks"

# --- CLI contract -----------------------------------------------------------

out=$(printf '%s\n' 'diff --git a/x b/x' '--- a/x' '+++ b/x' '@@ -0,0 +1 @@' '+y' \
  | bash "$REVIEW" --diff - --claim change) && code=0 || code=$?
expect_code 0 "$code" "stdin input works with --diff -"

# Readable streams are readable diffs: a pipe or process substitution is the
# natural shape of `git diff`, not a regular file.
out=$(bash "$REVIEW" --diff <(cat "$REAL_DIFF") --claim change) && code=0 || code=$?
expect_code 0 "$code" "process substitution is an accepted diff input"

out=$(cat "$REAL_DIFF" | bash "$REVIEW" --diff /dev/stdin --claim change) \
  && code=0 || code=$?
expect_code 0 "$code" "/dev/stdin is an accepted diff input"

out=$(bash "$REVIEW" --diff "$TMP_ROOT/does-not-exist.diff" --claim change 2>&1) \
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
for flag in --forbid-path --allow-path --require --exclude --claim --max-files --note; do
  out=$(bash "$REVIEW" --diff "$STATE_DIFF" "$flag" '' 2>&1) && code=0 || code=$?
  expect_code 2 "$code" "empty $flag value is a usage error"
  assert_not_contains "$out" "PASS" "empty $flag never reports PASS"
done

out=$(bash "$REVIEW" --diff '' --claim change 2>&1) && code=0 || code=$?
expect_code 2 "$code" "empty --diff value is a usage error"

# A final line without a trailing newline is still parsed.
out=$(printf 'diff --git a/x b/x\n@@ -0,0 +1 @@\n+new' \
  | bash "$REVIEW" --diff - --claim change) && code=0 || code=$?
expect_code 0 "$code" "unterminated final line is counted"
assert_contains "$out" "PASS (files=1, +1/-0)" "unterminated final added line is counted"

out=$(bash "$REVIEW" --diff "$REAL_DIFF" 2>&1) && code=0 || code=$?
expect_code 2 "$code" "no assertions requested is a usage error"

out=$(bash "$REVIEW" --diff "$REAL_DIFF" --claim change --nonsense 2>&1) \
  && code=0 || code=$?
expect_code 2 "$code" "unknown flag is a usage error"

out=$(bash "$REVIEW" --diff "$REAL_DIFF" --max-files many 2>&1) && code=0 || code=$?
expect_code 2 "$code" "non-integer --max-files is a usage error"

out=$(bash "$REVIEW" --help)
assert_contains "$out" "usage:" "--help prints usage"

pass "fm-diff-assert behavior"
