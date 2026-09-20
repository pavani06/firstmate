#!/usr/bin/env bash
# fm-diff-review.sh - deterministic, LLM-free review assertions over one
# unified diff: the fleet's deterministic diff-review layer
# (docs/deterministic-review.md owns the flow contract).
#
# Four assertions, all pure text functions (no model, no network, no
# randomness), reported as one readable PASS/FAIL verdict:
#   - claim consistency: a claim announcing a change over an empty diff fails,
#     and a no-change claim over a real diff fails (both directions of the
#     lab's no_op_consistency grader; a claim classifiable as neither is never
#     a failure)
#   - forbidden paths: any changed file under a --forbid-path prefix fails
#   - file limit: more than --max-files changed files fails
#
# Ported from pavani06/fleet-lab experiments/duolingo-graders/graders.py
# (DEC-002a evidence: 12/12 failed synthetic cases detected, 0 false positives
# over 10 real merged firstmate PRs), itself a port of the deterministic
# graders from Duolingo's engineering blog "How Duolingo Built a
# Production-Ready AI Agent Platform" (2026-08-04). Parsing semantics match
# the validated Python regexes exactly, including their header-exclusion edge
# cases noted inline.
#
# This is an optional review layer: it never replaces the no-mistakes
# pipeline's authority over validation or the captain's merge authority.
#
# Usage:
#   fm-diff-review.sh --diff <file|-> [--claim <text>] [--forbid-path P]... [--max-files N]
#   fm-diff-review.sh --help
#
# The diff is read from <file>, or from standard input when <file> is -.
# At least one assertion (--claim, --forbid-path, or --max-files) is required,
# because a review run with nothing to assert is a caller mistake.
# Exit codes: 0 all assertions passed, 1 at least one failed, 2 usage or read
# error.
set -eu

usage() {
  cat <<'USAGE'
usage:
  fm-diff-review.sh --diff <file|-> [--claim <text>] [--forbid-path P]... [--max-files N]
  fm-diff-review.sh --help

Run deterministic, LLM-free review assertions over one unified diff:
  --claim <text>     reported outcome; a change claim over an empty diff and a
                     no-change claim over a real diff both fail
  --forbid-path P    fail when a changed file sits under prefix P (repeatable)
  --max-files N      fail when the diff changes more than N files

The diff is read from <file>, or from standard input when <file> is -.
Exit codes: 0 pass, 1 failure, 2 usage or read error.
USAGE
}

die_usage() {
  printf 'error: %s\n' "$1" >&2
  usage >&2
  exit 2
}

DIFF_INPUT=''
CLAIM=''
MAX_FILES=''
FORBID_RAW=''
FORBID_PATHS=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --help | -h)
      usage
      exit 0
      ;;
    --diff)
      [ "$#" -ge 2 ] || die_usage "--diff requires a value"
      DIFF_INPUT=$2
      shift 2
      ;;
    --claim)
      [ "$#" -ge 2 ] || die_usage "--claim requires a value"
      CLAIM=$2
      shift 2
      ;;
    --forbid-path)
      [ "$#" -ge 2 ] || die_usage "--forbid-path requires a value"
      FORBID_RAW+=$2$'\n'
      shift 2
      ;;
    --max-files)
      [ "$#" -ge 2 ] || die_usage "--max-files requires a value"
      MAX_FILES=$2
      shift 2
      ;;
    *)
      die_usage "unknown argument: $1"
      ;;
  esac
done

if [ -z "$DIFF_INPUT" ]; then
  die_usage "--diff is required"
fi
case "$MAX_FILES" in
  '') ;;
  *[!0-9]*) die_usage "--max-files must be a non-negative integer" ;;
esac
if [ -z "$CLAIM" ] && [ -z "$FORBID_RAW" ] && [ -z "$MAX_FILES" ]; then
  die_usage "no assertions requested: pass --claim, --forbid-path, or --max-files"
fi

while IFS= read -r prefix; do
  [ -n "$prefix" ] || continue
  FORBID_PATHS+=("$prefix")
done <<EOF
$FORBID_RAW
EOF

if [ "$DIFF_INPUT" != '-' ] && [ ! -r "$DIFF_INPUT" ]; then
  printf 'error: cannot read diff file: %s\n' "$DIFF_INPUT" >&2
  exit 2
fi

# --- parse the diff ---------------------------------------------------------
# Matches graders.py exactly:
#   - changed files come from `diff --git a/X b/Y` headers, taking the b/
#     (new) path; the first ` b/` splits, matching the Python regex's
#     non-greedy a/ group, and both paths must be non-empty, matching its
#     .+? groups
#   - an added line starts with one `+` followed by a non-`+` byte, so the
#     `+++` header and a bare `+` line are never counted
#   - a removed line starts with one `-` followed by a non-`-` byte, so the
#     `---` header is never counted

CHANGED_FILES=()
FILE_COUNT=0
ADDED=0
REMOVED=0

while IFS= read -r line; do
  case "$line" in
    'diff --git a/'*)
      rest=${line#'diff --git a/'}
      case "$rest" in
        ?*' b/'?*)
          CHANGED_FILES+=("${rest#*' b/'}")
          FILE_COUNT=$((FILE_COUNT + 1))
          ;;
      esac
      ;;
    '+'[!+]*) ADDED=$((ADDED + 1)) ;;
    '-'[!-]*) REMOVED=$((REMOVED + 1)) ;;
  esac
done < <(
  if [ "$DIFF_INPUT" = '-' ]; then
    cat
  else
    cat -- "$DIFF_INPUT"
  fi
)

failures=''

# --- claim consistency ------------------------------------------------------

if [ -n "$CLAIM" ]; then
  lowered=$(printf '%s' "$CLAIM" | tr '[:upper:]' '[:lower:]')
  kind='unknown'
  # Negative phrases win over positive ones: "no change" contains "change",
  # so the no-change set is checked first, as in the validated grader.
  for phrase in \
    "no change" "no changes" "no op" "no-op" "noop" "no operation" \
    "nothing to change" "nothing changed" "nothing to do" "unchanged" \
    "no update" "no updates" "no modification" "no modifications" \
    "did not change" "didn't change" "did not modify" "didn't modify" \
    "no changes needed" "no changes required" "no change needed" \
    "no change required" "not needed" "no action" "no fix" "no work" \
    "no diff" "empty diff" "no work needed" "no work required" \
    "already up to date" "already correct" "already handled"; do
    case "$lowered" in
      *"$phrase"*) kind='no_change' ;;
    esac
    [ "$kind" = 'unknown' ] || break
  done
  if [ "$kind" = 'unknown' ]; then
    for phrase in \
      "fixed" "fix" "implemented" "implement" "added" "add" "changed" \
      "change" "updated" "update" "modified" "modify" "resolved" "resolve" \
      "completed" "done" "created" "create" "removed" "remove" "wrote" \
      "write" "patched" "patch" "refactored" "refactor" "renamed" \
      "moved" "move" "deleted" "delete"; do
      case "$lowered" in
        *"$phrase"*) kind='change' ;;
      esac
      [ "$kind" = 'unknown' ] || break
    done
  fi

  if [ "$kind" = 'no_change' ] && [ $((ADDED + REMOVED)) -gt 0 ]; then
    failures="${failures}  - claim says 'no change' but diff has +$ADDED/-$REMOVED lines"$'\n'
  fi
  if [ "$kind" = 'change' ] && [ $((ADDED + REMOVED)) -eq 0 ]; then
    failures="${failures}  - claim says a change was made but the diff is empty"$'\n'
  fi
fi

# --- forbidden paths --------------------------------------------------------

if [ "${#FORBID_PATHS[@]}" -gt 0 ] && [ "$FILE_COUNT" -gt 0 ]; then
  for prefix in "${FORBID_PATHS[@]}"; do
    for changed in "${CHANGED_FILES[@]}"; do
      case "$changed" in
        "$prefix"*)
          failures="${failures}  - forbidden path touched: '$changed' (forbidden prefix: $prefix)"$'\n'
          ;;
      esac
    done
  done
fi

# --- file limit -------------------------------------------------------------

if [ -n "$MAX_FILES" ] && [ "$FILE_COUNT" -gt "$MAX_FILES" ]; then
  failures="${failures}  - too many changed files: $FILE_COUNT > $MAX_FILES"$'\n'
fi

# --- report -----------------------------------------------------------------

if [ -n "$failures" ]; then
  printf 'FAIL\n'
  printf '%s' "$failures"
  exit 1
fi
printf 'PASS (files=%d, +%d/-%d)\n' "$FILE_COUNT" "$ADDED" "$REMOVED"
