#!/usr/bin/env bash
# fm-diff-assert.sh - deterministic, LLM-free review assertions over one
# unified diff, plus a line-anchored coverage skeleton: the fleet's
# deterministic diff-review layer (docs/deterministic-review.md owns the
# flow contract).
#
# Every run emits a COVERAGE block enumerating each hunk of the diff with its
# file and the old/new line ranges from its @@ header, so a reviewing agent
# always receives the full line-anchored surface it has to cover. A changed
# file that carries no hunk at all - a rename, a mode change, a binary
# rewrite - is listed under its structural markers instead, so no touched file
# is missing from that surface. A rename and a copy are both listed as
# `<from> -> <to>`, because git names both paths.
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
# a copy (copy from / copy to, which git emits under --find-copies or
# diff.renames=copies), a binary file (Binary files ... differ for a plain diff,
# GIT binary patch under --binary), a mode change (old mode / new mode), or a
# submodule record (Submodule <path> <old>..<new>, which git writes under
# diff.submodule=log or =diff). Git writes that record with no `diff --git`
# header of its own, so the record itself opens the stanza and names the
# submodule as a changed file; under diff.submodule=diff git then follows it
# with an ordinary superproject-relative stanza, which is read as any other
# file.
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
# Exit codes: 0 all assertions passed, 1 at least one failed, 2 usage error,
# read error, or a diff carrying content with no `diff --git` header.
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
a created, deleted, renamed, copied, mode-changed, binary or submodule file. A line is content only
inside a hunk body, so the ---/+++ headers never count while a line whose own
text starts with + or - always does.

--require and --exclude read added lines only, never headers, context lines or
removed lines.

Every run first prints a COVERAGE block naming each hunk of the diff with its
file and @@ line ranges, as the line-anchored surface a reviewer must cover. A
changed file with no hunk is listed under its structural markers instead.

The diff is read from <file>, or from standard input when <file> is -.
Exit codes: 0 pass, 1 failure, 2 usage error, read error, or a diff with
content but no 'diff --git' header.
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
# Content lines are classified by hunk state, not by their second byte. A hunk
# body opens at each `@@ <old-range> <new-range> @@` header and closes at the
# next `diff --git`; inside it, every line starting with `+` or `-` is content,
# whatever follows that marker, so a line whose own text begins with `+` or `-`
# is counted and searched like any other. Outside a hunk body no line is
# content, which is what excludes the `---`/`+++` file headers and a stray
# `+` or `-` that no hunk introduced.
#
# graders.py instead required the second byte to differ from the marker, which
# hides `++API_KEY = "sk-..."`, a deleted `- ` list item and every other line
# that repeats its marker. This port declares fidelity to the property that
# evidence measured - 12/12 detection with 0 false positives - and not to the
# mechanism that produced it, so the byte test is gone.
#
# A rename changes two paths, and both are the changed file: the destination
# from the header, and the source from the stanza's `rename from` line. Moving
# a file out of a directory is a touch of that directory, so both sides enter
# the path assertions and the coverage skeleton.
#
# A copy names two paths but changes only one. Its source is read, not written,
# so it is named in the coverage skeleton and deliberately kept out of the path
# assertions: only the destination is a changed file.
#
# File headers are read in the two spellings git writes, and only those:
#   - `diff --git a/X b/Y` yields the b/ (new) path; the first ` b/` splits,
#     matching the Python regex's non-greedy a/ group, and both paths must be
#     non-empty, matching its .+? groups
#   - `diff --git X X`, the prefix-less form of `--no-prefix` / diff.noprefix
#     for a non-rename, yields X - accepted only when the two fields are
#     byte-identical, which is the only case where the path is unambiguous
# Any other prefix pair (diff.mnemonicPrefix's `i/X w/X`, a custom src/dst
# prefix) leaves the changed file unresolvable: its path never enters prefix
# matching, and a requested --allow-path or --forbid-path fails rather than
# silently clearing a file it could not name. Diff content carrying no
# `diff --git` header at all is refused outright, because there is no file to
# resolve and no header to close the preceding hunk body.
#
# A rename or copy stanza is the exception, because its `rename to` / `copy to`
# line carries the destination as one unambiguous field. That names the file
# whatever the header spelling was, so such a stanza resolves from its own body
# and is never reported unresolvable.

CHANGED_FILES=()
FILE_COUNT=0
ADDED=0
REMOVED=0
STRUCTURAL=0
HUNK_COUNT=0
UNRESOLVED_HEADERS=()
COVERAGE=''
REQUIRE_SEEN=()
EXCLUDE_SEEN=()

# Resolve a `diff --git` header's remainder to the changed file, or to the
# empty string when no spelling names it unambiguously. Git C-quotes a field
# whose path needs escaping, and quotes each field independently, so a
# surrounding quote pair comes off either or both before the spellings are
# tested. A quote pair also delimits its field, which is why splitting on it is
# safe where splitting an unquoted pair on whitespace would not be.
#
# Git leaves a path containing spaces unquoted, so an `a/X b/Y` remainder can
# carry more than one ` b/`: `a/plan b/notes.md b/state b/secret.env` splits
# into `plan b/notes.md` -> `state b/secret.env` and into `plan` ->
# `notes.md b/state b/secret.env` equally well. Nothing in the header decides
# between them, so a second ` b/` makes the header unresolvable rather than
# letting the first one win and inventing a path.
# Remove a surrounding C-quote pair from one header field, leaving the escapes
# inside it exactly as git wrote them.
unquote_field() {  # <field>
  local field=$1
  case "$field" in
    '"'*'"')
      field=${field#'"'}
      field=${field%'"'}
      ;;
  esac
  printf '%s' "$field"
}

header_path() {  # <text after 'diff --git '>
  local rest=$1 first second half
  case "$rest" in
    '"'*'" '*)
      first=${rest#'"'}
      second=${first#*'" '}
      first=${first%%'" '*}
      ;;
    *' "'*'"')
      first=${rest% '"'*}
      second=${rest##* '"'}
      second=${second%'"'}
      ;;
    *)
      first=''
      ;;
  esac
  if [ -n "$first" ]; then
    rest="$first $(unquote_field "$second")"
  fi

  case "$rest" in
    'a/'?*' b/'?*)
      second=${rest#*' b/'}
      case "$second" in
        *' b/'*) return 0 ;;
      esac
      printf '%s' "$second"
      return 0
      ;;
  esac
  half=$(( (${#rest} - 1) / 2 ))
  if [ "$half" -gt 0 ] && [ "${rest:half:1}" = ' ' ] \
    && [ "${rest:0:half}" = "${rest:half + 1}" ]; then
    printf '%s' "${rest:0:half}"
  fi
}

# Record a structural marker against the stanza being parsed, once per kind.
add_marker() {  # <label>
  case ", $stanza_markers, " in
    *", $1, "*) return 0 ;;
  esac
  stanza_markers="${stanza_markers}${stanza_markers:+, }$1"
}

# Resolve a `Submodule ` record's remainder to the submodule path, or to the
# empty string when the record does not name one unambiguously. Git writes the
# record as `<path> <old>..<new>` with an optional ` (<state>)` suffix and an
# optional trailing colon, and it leaves a path containing spaces unquoted, so
# the `<old>..<new>` field is read off the end and everything before it is the
# path.
submodule_path() {  # <text after 'Submodule '>
  local rest=$1 range
  rest=${rest%:}
  case "$rest" in
    *' ('*')') rest=${rest% (*)} ;;
  esac
  range=${rest##* }
  case "$range" in
    *'..'*) ;;
    *) return 0 ;;
  esac
  rest=${rest% "$range"}
  [ -n "$rest" ] || return 0
  printf '%s' "$rest"
}

# Open the stanza a file record introduces, closing the one before it. The
# record names one changed file whether it is a `diff --git` header or a
# `Submodule ` record, so both reach the path assertions, the file limit and
# the coverage skeleton through here.
open_stanza() {  # <resolved path or empty> <record line> <record remainder>
  flush_stanza
  in_hunk=0
  stanza_header=$2
  if [ -n "$1" ]; then
    current=$1
    CHANGED_FILES+=("$current")
    stanza_unresolved=0
  else
    current="(unresolved path: $3)"
    stanza_unresolved=1
  fi
  FILE_COUNT=$((FILE_COUNT + 1))
  stanza_file=$current
  stanza_hunks=0
  stanza_markers=''
  stanza_from=''
}

# A rename or copy destination arrives as one unambiguous field, so it names
# the changed file even when the stanza's header spelling could not.
resolve_destination() {  # <raw destination field>
  local dest
  dest=$(unquote_field "$1")
  [ -n "$dest" ] || return 0
  if [ "$stanza_unresolved" -eq 1 ]; then
    stanza_unresolved=0
    CHANGED_FILES+=("$dest")
  fi
  current=$dest
  stanza_file="${stanza_from:+$stanza_from -> }$dest"
}

# Close the stanza being parsed. A stanza still unresolved at its close is
# recorded here rather than at its header, because a later `rename to` or
# `copy to` line can still name the file. A stanza that carried no hunk names a
# changed file too, so it enters the coverage skeleton under its markers rather
# than a line range; otherwise its hunks already listed it.
flush_stanza() {
  [ -n "$stanza_file" ] || return 0
  if [ "$stanza_unresolved" -eq 1 ]; then
    UNRESOLVED_HEADERS+=("$stanza_header")
  fi
  [ "$stanza_hunks" -eq 0 ] || return 0
  COVERAGE="${COVERAGE}  $stanza_file - ${stanza_markers:+$stanza_markers, }no hunk"$'\n'
}

parse_diff() {
  local line rest ranges body in_hunk=0 current='(unknown file)' i
  local stanza_file='' stanza_hunks=0 stanza_markers='' stanza_from=''
  local stanza_header='' stanza_unresolved=0
  local nreq=${#REQUIRE[@]} nexc=${#EXCLUDE[@]}
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      'diff --git '*)
        rest=${line#'diff --git '}
        open_stanza "$(header_path "$rest")" "$line" "$rest"
        ;;
      'new file mode '?*)
        STRUCTURAL=1
        add_marker created
        ;;
      'deleted file mode '?*)
        STRUCTURAL=1
        add_marker deleted
        ;;
      'rename from '?*)
        STRUCTURAL=1
        add_marker renamed
        stanza_from=$(unquote_field "${line#'rename from '}")
        CHANGED_FILES+=("$stanza_from")
        stanza_file="$stanza_from -> $current"
        ;;
      'rename to '?*)
        STRUCTURAL=1
        add_marker renamed
        resolve_destination "${line#'rename to '}"
        ;;
      'copy from '?*)
        STRUCTURAL=1
        add_marker copied
        stanza_from=$(unquote_field "${line#'copy from '}")
        stanza_file="$stanza_from -> $current"
        ;;
      'copy to '?*)
        STRUCTURAL=1
        add_marker copied
        resolve_destination "${line#'copy to '}"
        ;;
      'old mode '?* | 'new mode '?*)
        STRUCTURAL=1
        add_marker 'mode change'
        ;;
      'Binary files '*' differ' | 'GIT binary patch')
        STRUCTURAL=1
        add_marker binary
        ;;
      'Submodule '?*' '?*'..'?*)
        rest=${line#'Submodule '}
        open_stanza "$(submodule_path "$rest")" "$line" "$rest"
        STRUCTURAL=1
        add_marker submodule
        ;;
      '@@ '*' @@'*)
        in_hunk=1
        ranges=${line#'@@ '}
        ranges=${ranges%%' @@'*}
        COVERAGE="${COVERAGE}  $stanza_file @@ $ranges @@"$'\n'
        HUNK_COUNT=$((HUNK_COUNT + 1))
        stanza_hunks=$((stanza_hunks + 1))
        ;;
      '+'*)
        [ "$in_hunk" -eq 1 ] || continue
        ADDED=$((ADDED + 1))
        body=${line#+}
        for ((i = 0; i < nreq; i++)); do
          case "$body" in *"${REQUIRE[i]}"*) REQUIRE_SEEN[i]=1 ;; esac
        done
        for ((i = 0; i < nexc; i++)); do
          case "$body" in *"${EXCLUDE[i]}"*) EXCLUDE_SEEN[i]=1 ;; esac
        done
        ;;
      '-'*)
        [ "$in_hunk" -eq 1 ] || continue
        REMOVED=$((REMOVED + 1))
        ;;
    esac
  done
  flush_stanza
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

# Every file of a git unified diff opens with its own `diff --git` header, and
# that header is what closes the previous file's hunk body. Diff content with
# no header at all is therefore not a shape this layer can read: the file has
# no name for the path assertions, and one file's `---`/`+++` lines would be
# counted and searched as the previous file's added content. Refuse it rather
# than return a verdict over a partial parse.
if [ "$FILE_COUNT" -eq 0 ] \
  && { [ "$HUNK_COUNT" -gt 0 ] || [ "$STRUCTURAL" -eq 1 ]; }; then
  printf 'error: diff has content but no %s header; this layer reads git unified diffs, which carry one %s header per file\n' \
    "'diff --git'" "'diff --git'" >&2
  exit 2
fi

failures=''

# --- claim consistency ------------------------------------------------------

CHANGE_EVIDENCE=''
if [ $((ADDED + REMOVED)) -gt 0 ]; then
  CHANGE_EVIDENCE="+$ADDED/-$REMOVED lines"
elif [ "$HUNK_COUNT" -gt 0 ]; then
  CHANGE_EVIDENCE="$HUNK_COUNT hunk(s) of changed lines"
elif [ "$STRUCTURAL" -eq 1 ]; then
  CHANGE_EVIDENCE='a created, deleted, renamed, copied, mode-changed, binary or submodule file'
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

if { [ "${#ALLOW_PATHS[@]}" -gt 0 ] || [ "${#FORBID_PATHS[@]}" -gt 0 ]; } \
  && [ "${#UNRESOLVED_HEADERS[@]}" -gt 0 ]; then
  for header in "${UNRESOLVED_HEADERS[@]}"; do
    failures="${failures}  - changed file unresolvable from its header, so its path cannot be asserted: '$header'"$'\n'
  done
fi

if [ "${#ALLOW_PATHS[@]}" -gt 0 ] && [ "${#CHANGED_FILES[@]}" -gt 0 ]; then
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

if [ "${#FORBID_PATHS[@]}" -gt 0 ] && [ "${#CHANGED_FILES[@]}" -gt 0 ]; then
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
