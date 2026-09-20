#!/usr/bin/env bash
# fm-diff-review.sh - deterministic, LLM-free review assertions over one
# unified diff, plus a line-anchored coverage skeleton: the fleet's
# deterministic diff-review layer (docs/deterministic-review.md owns the
# flow contract).
#
# Every run emits a COVERAGE block enumerating each hunk of the diff with its
# file and the old/new line ranges from its @@ header, so a reviewing agent
# always receives the full line-anchored surface it has to cover.
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
# Production-Ready AI Agent Platform" (2026-08-04). Diff parsing matches the
# validated Python regexes exactly, including their header-exclusion edge
# cases noted inline.
#
# Claim classification deliberately diverges from the lab source's literal
# phrase lists, because the property the DEC-002a evidence measured is zero
# false positives, and bare substring matching does not hold it: it classified
# "unresolved" as resolve, "prefix" as fix and "dispatch" as patch. Phrases are
# matched on word boundaries with explicit inflection suffixes instead, and the
# no-change set recognises a negation separated from its noun ("no code change")
# so an explicit negation outranks any positive word in the same claim. Because
# a stem now covers its own inflections and a noun covers its own plural, the
# redundant entries of both lab lists ("fixed" beside "fix", "no changes
# needed" beside "no change", and so on) are gone rather than repeated.
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
# because a review run with nothing to assert is a caller mistake, and every
# flag requires a non-empty value, because an empty one would silently disable
# the assertion it asked for.
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

Every run first prints a COVERAGE block naming each hunk of the diff with its
file and @@ line ranges, as the line-anchored surface a reviewer must cover.

The diff is read from <file>, or from standard input when <file> is -.
Exit codes: 0 pass, 1 failure, 2 usage or read error.
USAGE
}

die_usage() {
  printf 'error: %s\n' "$1" >&2
  usage >&2
  exit 2
}

require_value() {
  [ "$2" -ge 2 ] || die_usage "$1 requires a value"
  [ -n "$3" ] || die_usage "$1 requires a non-empty value"
}

DIFF_INPUT=''
CLAIM=''
MAX_FILES=''
FORBID_PATHS=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --help | -h)
      usage
      exit 0
      ;;
    --diff)
      require_value --diff "$#" "${2-}"
      DIFF_INPUT=$2
      shift 2
      ;;
    --claim)
      require_value --claim "$#" "${2-}"
      CLAIM=$2
      shift 2
      ;;
    --forbid-path)
      require_value --forbid-path "$#" "${2-}"
      FORBID_PATHS+=("$2")
      shift 2
      ;;
    --max-files)
      require_value --max-files "$#" "${2-}"
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
if [ -z "$CLAIM" ] && [ "${#FORBID_PATHS[@]}" -eq 0 ] && [ -z "$MAX_FILES" ]; then
  die_usage "no assertions requested: pass --claim, --forbid-path, or --max-files"
fi

if [ "$DIFF_INPUT" != '-' ] && { [ ! -f "$DIFF_INPUT" ] || [ ! -r "$DIFF_INPUT" ]; }; then
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
# Hunk headers are `@@ <old-range> <new-range> @@`, attributed to the file
# header that precedes them.

CHANGED_FILES=()
FILE_COUNT=0
ADDED=0
REMOVED=0
HUNK_COUNT=0
COVERAGE=''

parse_diff() {
  local line rest ranges current='(unknown file)'
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      'diff --git a/'*)
        rest=${line#'diff --git a/'}
        case "$rest" in
          ?*' b/'?*)
            current=${rest#*' b/'}
            CHANGED_FILES+=("$current")
            FILE_COUNT=$((FILE_COUNT + 1))
            ;;
        esac
        ;;
      '@@ '*' @@'*)
        ranges=${line#'@@ '}
        ranges=${ranges%%' @@'*}
        COVERAGE="${COVERAGE}  $current @@ $ranges @@"$'\n'
        HUNK_COUNT=$((HUNK_COUNT + 1))
        ;;
      '+'[!+]*) ADDED=$((ADDED + 1)) ;;
      '-'[!-]*) REMOVED=$((REMOVED + 1)) ;;
    esac
  done
  return 0
}

if [ "$DIFF_INPUT" = '-' ]; then
  parse_diff
else
  parse_diff < "$DIFF_INPUT" || {
    printf 'error: cannot read diff file: %s\n' "$DIFF_INPUT" >&2
    exit 2
  }
fi

failures=''

# --- claim consistency ------------------------------------------------------

# Each pattern is matched as a whole word: bounded by the start or end of the
# claim, or by a byte that is not a lowercase letter or digit.
matches_word() {
  local text=$1 pattern
  shift
  for pattern in "$@"; do
    if [[ $text =~ (^|[^a-z0-9])($pattern)($|[^a-z0-9]) ]]; then
      return 0
    fi
  done
  return 1
}

# Negation of a change noun, with or without a modifier between the two
# ("no change", "no code change"), so an explicit negation classifies the
# claim even when it also carries a positive word.
NO_CHANGE_PATTERNS=(
  'no( [a-z][a-z-]*)? (change|update|modification|edit|fix|diff|action|work|operation|op)s?'
  'no-?ops?'
  'nothing (to change|changed|to do|to fix)'
  'unchanged'
  '(did|does) not (change|modify)'
  "(didn't|doesn't) (change|modify)"
  'not needed'
  'empty diff'
  'already (up to date|correct|handled)'
)

# Stems carry their own inflections, so "fix" classifies "fixes", "fixed" and
# "fixing" while leaving "prefix" alone.
CHANGE_PATTERNS=(
  '(fix|implement|add|change|update|modify|resolve|complete|create|remove|write|patch|refactor|rename|move|delete)(s|d|es|ed|ing)?'
  'modifie[ds]'
  'wrote'
  'done'
)

if [ -n "$CLAIM" ]; then
  lowered=$(printf '%s' "$CLAIM" | tr '[:upper:]' '[:lower:]')
  kind='unknown'
  if matches_word "$lowered" "${NO_CHANGE_PATTERNS[@]}"; then
    kind='no_change'
  elif matches_word "$lowered" "${CHANGE_PATTERNS[@]}"; then
    kind='change'
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

printf 'COVERAGE (hunks=%d)\n' "$HUNK_COUNT"
printf '%s' "$COVERAGE"

if [ -n "$failures" ]; then
  printf 'FAIL\n'
  printf '%s' "$failures"
  exit 1
fi
printf 'PASS (files=%d, +%d/-%d)\n' "$FILE_COUNT" "$ADDED" "$REMOVED"
