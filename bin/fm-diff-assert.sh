#!/usr/bin/env bash
# fm-diff-assert.sh - deterministic, LLM-free review assertions over one
# unified diff, plus a line-anchored coverage skeleton: the fleet's
# deterministic diff-review layer (docs/deterministic-review.md owns the
# flow contract).
#
# Every run emits a COVERAGE block enumerating each hunk of the diff with its
# file and the old/new line ranges from its @@ header, so a reviewing agent
# always receives the full line-anchored surface it has to cover.
#
# The assertions are pure text functions (no model, no network, no
# randomness), reported as one readable PASS/FAIL verdict:
#   - claim consistency: --claim change over an empty diff fails, and
#     --claim no-change over a diff that changes anything fails
#   - required text: every --require substring must appear on some added line
#   - forbidden text: no --exclude substring may appear on any added line
#   - allowed paths: every changed file must sit under some --allow-path prefix
#   - forbidden paths: any changed file under a --forbid-path prefix fails
#   - file limit: more than --max-files changed files fails
#
# Ported from pavani06/fleet-lab experiments/duolingo-graders/graders.py
# (DEC-002a evidence: 12/12 planted synthetic failures detected, 0 false
# positives over 10 real merged firstmate PRs), itself a port of the
# deterministic graders from Duolingo's engineering blog "How Duolingo Built a
# Production-Ready AI Agent Platform" (2026-08-04).
#
# What this port declares fidelity to is that measured property - 12/12
# detection with 0 false positives - and not to the lab source's prose parser.
# The lab classified a free-text claim by matching change and no-change phrase
# lists against it, which cannot hold the zero-false-positive property: every
# round of review found more truthful prose it misread ("unresolved" as
# resolve, "prefix" as fix, "no functional changes" as an empty-diff claim,
# "done investigating" as an edit). The classifier is therefore gone, on
# purpose: --claim takes the verdict itself, change or no-change, and free text
# belongs in --note, which is printed and never interpreted. With no language
# to parse, the claim assertion is a comparison between a typed verdict and a
# parsed diff fact, and false positives are impossible by construction.
#
# A diff changes something when it has +/- content lines, when it has a hunk
# (git writes an @@ header only for a region it found different, so a hunk whose
# only edit is a blank line still changed the file), or when it carries a
# structural marker that changes a file without either: a created or deleted
# file (new file mode / deleted file mode), a rename (rename from / rename to),
# a binary file (Binary files ... differ), or a mode change (old mode /
# new mode).
#
# --require and --exclude read the added lines only, never headers, hunk
# headers, unchanged context lines or removed lines. Matching a context line
# would fail a diff for code it did not introduce, and matching a removed line
# or a file header would clear a --require the change never satisfied.
#
# This is an optional review layer: it never replaces the no-mistakes
# pipeline's authority over validation or the captain's merge authority.
#
# Usage:
#   fm-diff-assert.sh --diff <file|-> [--claim change|no-change] [--note <text>]
#                     [--require S]... [--exclude S]... [--allow-path P]...
#                     [--forbid-path P]... [--max-files N]
#   fm-diff-assert.sh --help
#
# The diff is read from <file>, or from standard input when <file> is -.
# At least one assertion is required, because a review run with nothing to
# assert is a caller mistake, and every flag requires a non-empty value,
# because an empty one would silently disable the assertion it asked for.
# Exit codes: 0 all assertions passed, 1 at least one failed, 2 usage or read
# error.
set -eu

usage() {
  cat <<'USAGE'
usage:
  fm-diff-assert.sh --diff <file|-> [--claim change|no-change] [--note <text>]
                    [--require S]... [--exclude S]... [--allow-path P]...
                    [--forbid-path P]... [--max-files N]
  fm-diff-assert.sh --help

Run deterministic, LLM-free review assertions over one unified diff:
  --claim change     fail when the diff changes nothing
  --claim no-change  fail when the diff changes anything
  --note <text>      free-text remark, printed in the report and never
                     interpreted; it is not an assertion
  --require S        fail when substring S is on no added line (repeatable)
  --exclude S        fail when substring S is on some added line (repeatable)
  --allow-path P     fail when a changed file sits under no allowed prefix
                     (repeatable)
  --forbid-path P    fail when a changed file sits under prefix P (repeatable)
  --max-files N      fail when the diff changes more than N files

A diff changes something when it has +/- content lines, a hunk, or a marker for
a created, deleted, renamed, mode-changed or binary file.

--require and --exclude read added lines only, never headers, context lines or
removed lines.

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
NOTE=''
MAX_FILES=''
REQUIRE=()
EXCLUDE=()
ALLOW_PATHS=()
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
      case "$2" in
        change | no-change) CLAIM=$2 ;;
        *) die_usage "--claim must be exactly 'change' or 'no-change', not: $2" ;;
      esac
      shift 2
      ;;
    --note)
      require_value --note "$#" "${2-}"
      NOTE=$2
      shift 2
      ;;
    --require)
      require_value --require "$#" "${2-}"
      REQUIRE+=("$2")
      shift 2
      ;;
    --exclude)
      require_value --exclude "$#" "${2-}"
      EXCLUDE+=("$2")
      shift 2
      ;;
    --allow-path)
      require_value --allow-path "$#" "${2-}"
      ALLOW_PATHS+=("$2")
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
if [ -z "$CLAIM" ] && [ -z "$MAX_FILES" ] \
  && [ "${#REQUIRE[@]}" -eq 0 ] && [ "${#EXCLUDE[@]}" -eq 0 ] \
  && [ "${#ALLOW_PATHS[@]}" -eq 0 ] && [ "${#FORBID_PATHS[@]}" -eq 0 ]; then
  die_usage "no assertions requested: pass --claim, --require, --exclude, --allow-path, --forbid-path, or --max-files"
fi

if [ "$DIFF_INPUT" != '-' ] && { [ -d "$DIFF_INPUT" ] || [ ! -r "$DIFF_INPUT" ]; }; then
  printf 'error: cannot read diff file: %s\n' "$DIFF_INPUT" >&2
  exit 2
fi

# --- parse the diff ---------------------------------------------------------
# Follows graders.py, with the file header widened to the prefix-less spelling
# git emits under diff.noprefix / --no-prefix, so a changed file is never
# invisible to the path and file-count assertions:
#   - `diff --git a/X b/Y` yields the b/ (new) path; the first ` b/` splits,
#     matching the Python regex's non-greedy a/ group, and both paths must be
#     non-empty, matching its .+? groups
#   - any other `diff --git X Y` header yields its last field, which is the
#     same new path git writes in the b/ position
#   - an added line starts with one `+` followed by a non-`+` byte, so the
#     `+++` header and a bare `+` line are never counted; its content, with
#     that `+` stripped, is what --require and --exclude match against
#   - a removed line starts with one `-` followed by a non-`-` byte, so the
#     `---` header is never counted
# Hunk headers are `@@ <old-range> <new-range> @@`, attributed to the file
# header that precedes them.

CHANGED_FILES=()
FILE_COUNT=0
ADDED=0
REMOVED=0
STRUCTURAL=0
HUNK_COUNT=0
COVERAGE=''
REQUIRE_SEEN=()
EXCLUDE_SEEN=()

parse_diff() {
  local line rest ranges added current='(unknown file)' i
  local nreq=${#REQUIRE[@]} nexc=${#EXCLUDE[@]}
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      'diff --git '*)
        rest=${line#'diff --git '}
        case "$rest" in
          'a/'?*' b/'?*) current=${rest#*' b/'} ;;
          *' '?*) current=${rest##* } ;;
          *) current='(unknown file)' ;;
        esac
        CHANGED_FILES+=("$current")
        FILE_COUNT=$((FILE_COUNT + 1))
        ;;
      'new file mode '?* | 'deleted file mode '?* | 'rename from '?* \
        | 'rename to '?* | 'old mode '?* | 'new mode '?*)
        STRUCTURAL=1
        ;;
      'Binary files '*' differ')
        STRUCTURAL=1
        ;;
      '@@ '*' @@'*)
        ranges=${line#'@@ '}
        ranges=${ranges%%' @@'*}
        COVERAGE="${COVERAGE}  $current @@ $ranges @@"$'\n'
        HUNK_COUNT=$((HUNK_COUNT + 1))
        ;;
      '+'[!+]*)
        ADDED=$((ADDED + 1))
        added=${line#+}
        for ((i = 0; i < nreq; i++)); do
          case "$added" in *"${REQUIRE[i]}"*) REQUIRE_SEEN[i]=1 ;; esac
        done
        for ((i = 0; i < nexc; i++)); do
          case "$added" in *"${EXCLUDE[i]}"*) EXCLUDE_SEEN[i]=1 ;; esac
        done
        ;;
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

CHANGE_EVIDENCE=''
if [ $((ADDED + REMOVED)) -gt 0 ]; then
  CHANGE_EVIDENCE="+$ADDED/-$REMOVED lines"
elif [ "$HUNK_COUNT" -gt 0 ]; then
  CHANGE_EVIDENCE="$HUNK_COUNT hunk(s) of changed lines"
elif [ "$STRUCTURAL" -eq 1 ]; then
  CHANGE_EVIDENCE='a created, deleted, renamed, mode-changed or binary file'
fi

if [ "$CLAIM" = 'change' ] && [ -z "$CHANGE_EVIDENCE" ]; then
  failures="${failures}  - claim is 'change' but the diff changes nothing"$'\n'
fi
if [ "$CLAIM" = 'no-change' ] && [ -n "$CHANGE_EVIDENCE" ]; then
  failures="${failures}  - claim is 'no-change' but the diff has $CHANGE_EVIDENCE"$'\n'
fi

# --- required and forbidden text --------------------------------------------

for ((i = 0; i < ${#REQUIRE[@]}; i++)); do
  if [ "${REQUIRE_SEEN[i]-0}" != 1 ]; then
    failures="${failures}  - required text on no added line: '${REQUIRE[i]}'"$'\n'
  fi
done

for ((i = 0; i < ${#EXCLUDE[@]}; i++)); do
  if [ "${EXCLUDE_SEEN[i]-0}" = 1 ]; then
    failures="${failures}  - forbidden text on an added line: '${EXCLUDE[i]}'"$'\n'
  fi
done

# --- allowed and forbidden paths --------------------------------------------

if [ "${#ALLOW_PATHS[@]}" -gt 0 ] && [ "$FILE_COUNT" -gt 0 ]; then
  for changed in "${CHANGED_FILES[@]}"; do
    allowed=0
    for prefix in "${ALLOW_PATHS[@]}"; do
      case "$changed" in
        "$prefix"*)
          allowed=1
          break
          ;;
      esac
    done
    if [ "$allowed" -eq 0 ]; then
      failures="${failures}  - changed file outside allowed paths: '$changed' (allowed prefixes: ${ALLOW_PATHS[*]})"$'\n'
    fi
  done
fi

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
if [ -n "$NOTE" ]; then
  printf 'NOTE: %s\n' "$NOTE"
fi

if [ -n "$failures" ]; then
  printf 'FAIL\n'
  printf '%s' "$failures"
  exit 1
fi
printf 'PASS (files=%d, +%d/-%d)\n' "$FILE_COUNT" "$ADDED" "$REMOVED"
