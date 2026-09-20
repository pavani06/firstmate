# Deterministic diff review layer

Fleet PR review has a deterministic, LLM-free layer that asserts structural properties of a task diff before or alongside agent reasoning, and hands the reviewer a line-anchored map of everything the diff touches.
It catches the two signature coding-agent failure modes, claim-without-diff and no-op-with-diff, plus five diff-shape guards over text, paths and size, at zero token cost and with fully reproducible verdicts.
The script is `bin/fm-diff-assert.sh`; its header and `--help` own the exact flags and parsing semantics.
This layer is optional: the no-mistakes pipeline stays the owner of validation, and merge authority is unchanged.

## Where it came from

The assertions are a port of the two deterministic graders from Duolingo's engineering blog "How Duolingo Built a Production-Ready AI Agent Platform" (2026-08-04), via the `pavani06/fleet-lab` graduation experiments.
The lab evidence (DEC-002a) measured 12/12 detection of planted synthetic failures and 0 false positives across 10 real merged firstmate PRs.
The port keeps the validated diff-parsing semantics, and `tests/fm-diff-assert.test.sh` carries the lab's 12 planted failures and 3 clean controls one-for-one so that measured property is what CI holds.

What the port is faithful to is that measured property, not the lab source's mechanism.
The lab classified a free-text claim by matching phrase lists against it, and no version of that classifier held the zero-false-positive line: it read "unresolved" as resolve, "prefix" as fix, "no functional changes" as a claim of an empty diff, and "done investigating" as an edit.
So the classifier is gone on purpose. `--claim` takes the verdict itself - `change` or `no-change` - and free text goes to `--note`, which is printed and never interpreted.
With no language to parse, the claim assertion is a comparison between a typed verdict and a parsed diff fact, and this class of false positive cannot occur.

## Line-anchored coverage

Every run first prints a `COVERAGE` block that enumerates each hunk of the diff with its file and the old/new line ranges from its `@@` header:

```
COVERAGE (hunks=2)
  bin/one.sh @@ -1,2 +1,3 @@
  docs/two.md @@ -7 +7,2 @@
```

A changed file that carries no hunk at all is listed under its structural markers instead of a line range:

```
COVERAGE (hunks=0)
  state/secret.env -> state/moved.env - renamed, no hunk
  assets/logo.png - binary, no hunk
  run.sh - mode change, no hunk
```

This is the deterministic half of the DEC-003 line-by-line objective: the reviewing agent consumes the block as the guaranteed surface it has to cover, so no touched region of the diff goes unexamined because the agent never noticed it.
Every file git names in the diff appears in the block, whether or not it has hunks.
Producing the skeleton needs nothing beyond the diff itself - no CLI, no dependency, no tokens.

## The assertions

- Claim consistency: `--claim change` fails when the diff changes nothing, and `--claim no-change` fails when the diff changes anything.
  The flag takes exactly one of those two tokens; anything else is a usage error, so no prose is ever classified.
  `--note <text>` carries the worker's own wording into the report untouched and asserts nothing.
- Required text: every `--require` substring must appear on some added line.
- Forbidden text: no `--exclude` substring may appear on any added line, for example `sk-` or a stray debug print.
  Both read added lines only - never headers, hunk headers, unchanged context lines or removed lines - because matching a context line would fail a change for code it did not introduce, and matching a removed line or a file header would clear a `--require` the change never satisfied.
  An added line is any line starting with `+` inside a hunk body, and what they match against is its text with that `+` removed.
- Allowed paths: every changed file must sit under some `--allow-path` prefix.
- Forbidden paths: any changed file under a `--forbid-path` prefix fails, for example to notice a worker that touched `state/` or `.env`.
- File limit: more than `--max-files` changed files fails.

## When a diff changes something

A diff changes something when any of three kinds of evidence is present:

- `+`/`-` content lines.
- A hunk that carries no content line. Git writes an `@@` header only for a region it found different, so a truncated or hand-edited diff whose content lines are gone still counts as a change rather than grading itself empty. Every `@@` header git writes for a whole diff has content under it, so this is deliberate fail-closed insurance against degenerate input, not a rule ordinary diffs meet.
- A marker for a change that has neither: a created or deleted file (`new file mode` / `deleted file mode`), a rename (`rename from` / `rename to`), a copy (`copy from` / `copy to`, which git emits under `--find-copies` or `diff.renames=copies`), a binary file (`Binary files ... differ`), or a mode change (`old mode` / `new mode`).

So a pure rename, a chmod, a replaced image, an added blank line and an empty `.gitkeep` are all real changes: `--claim change` passes over them and `--claim no-change` fails.
A stanza that is only `---`/`+++` header lines, or a bare `+` outside any hunk, changes nothing and counts as empty.

A line is content only inside a hunk body, which opens at each `@@` header and closes at the next `diff --git`.
Inside one, every line starting with `+` or `-` is content whatever follows that marker, so `++API_KEY = "sk-..."` and a deleted `- ` list item are counted and searched like any other line.
The lab source instead required the second byte to differ from the marker, which hid both; the property that evidence measured is what this port keeps, not the mechanism that produced it.

A rename changes two paths, and both count as the changed file: the destination from the header, and the source from the stanza's `rename from` line.
Moving a file out of a directory is a touch of that directory, so `--forbid-path state/` fails on `git mv state/secret.env docs/secret.env` and the coverage block lists the stanza as `state/secret.env -> docs/secret.env`.
The file limit is unaffected: `--max-files` still counts one changed file per `diff --git` stanza.

A copy names two paths but changes only one.
Its source is read, not written, so the coverage block lists the stanza as `state/secret.env -> docs/secret.env` while only the destination enters the path assertions: `--forbid-path docs/` fails on a copy into `docs/`, and `--forbid-path state/` does not fail on a copy out of an untouched `state/`.

File headers are read in the two spellings git writes, and only those: `diff --git a/X b/Y`, and the prefix-less `diff --git X X` that `--no-prefix` or `diff.noprefix=true` produces for a non-rename, accepted only when its two fields are byte-identical.
Git C-quotes a field whose path needs escaping, independently per field (`diff --git a/plain.md "b/caf\303\251.md"`), so a surrounding quote pair is removed from either or both fields before those two spellings are tested.
Only that quote pair comes off: the C escapes inside the field are left as git wrote them, so such a path is matched in its escaped spelling (`docs/caf\303\251.md`, not `docs/café.md`).
Prefixes for `--allow-path` and `--forbid-path` therefore have to be ASCII to match a C-quoted path - `--forbid-path docs/` works, `--forbid-path 'docs/café'` cannot match. Decoding git's escape alphabet is deliberately not done until a concrete need appears.
Git leaves a path containing spaces unquoted, which can make an `a/X b/Y` header carry a second ` b/` (`a/plan b/notes.md b/state b/secret.env`); nothing in the header says which one splits it, so that header is unresolvable too rather than resolved to an invented path.
Any other prefix pair - `diff.mnemonicPrefix`'s `i/X w/X`, a custom src/dst prefix - leaves the changed file unresolvable.
A rename or copy stanza is the exception: its `rename to` / `copy to` line carries the destination as one unambiguous field, so the stanza resolves from its own body whatever its header spelling was, and a prefix-less or ambiguous rename is named rather than refused.
Such a file still counts toward `--max-files`, but its path never enters prefix matching: a requested `--allow-path` or `--forbid-path` fails and names the header instead, because a path guard that cannot name its file must not clear it.

Diff content carrying no `diff --git` header at all is refused outright, with exit 2 and no verdict.
That header is also what closes the previous file's hunk body, so without it one file's `---`/`+++` lines would be counted and searched as the previous file's added content, and no file would have a name for the path assertions.
A partial parse of such input can only produce a verdict that is wrong in both directions, so the layer declines to give one.

## Running it

The diff is read from a file or from standard input, so any source of a git unified diff works: `git diff`, `gh pr diff` and `bin/fm-review-diff.sh` all emit the `diff --git` headers this layer reads.

```sh
git diff main...HEAD | bin/fm-diff-assert.sh --diff - \
  --claim change --note "fixed the flaky login test" --forbid-path state/ --max-files 20
gh pr diff 1234 > /tmp/pr.diff
bin/fm-diff-assert.sh --diff /tmp/pr.diff --claim change --allow-path tests/ --exclude 'sk-'
```

A worker that investigated and edited nothing reports that as a verdict too:

```sh
git diff main...HEAD | bin/fm-diff-assert.sh --diff - \
  --claim no-change --note "checked the dispatch table; no code change was warranted"
```

Exit codes: 0 all assertions passed, 1 at least one failed, 2 usage error, read error, or a diff carrying content with no `diff --git` header.
At least one assertion must be requested, because a review run with nothing to assert is a caller mistake; `--note` is not an assertion.
Every flag requires a non-empty value, because an empty one would otherwise silently disable the assertion it asked for.
A diff the layer cannot read is a read error, never a PASS: a verdict is only worth its input.
Any readable stream is a valid `--diff`, including a pipe, a process substitution and `/dev/stdin`; a directory is not.

## Where it fits in the fleet PR flow

Run it at the validation point, before or alongside the agent's own review of the diff.
The fleet reaches it from two places: a ship brief's definition of done tells the worker to run the pass over its own branch diff and report what it printed, and `bin/fm-review-diff.sh`, which resolves the authoritative task diff for review, is the natural producer to pipe into it.
It is an input to review, not a gate: this graduation adds no required check, changes no merge authority, and does not modify `fm-pr-check.sh` or `fm-pr-merge.sh`.
A worker or reviewer can cite the verdict in a PR body or task report; a FAIL line names each failure directly.

## open-code-review (OCR) in delegation mode - documented, not installed

The line-anchored coverage above already delivers the DEC-003 objective without any new dependency; what follows is the evaluated CLI path, recorded as a possible future upgrade only.

The lab's DEC-003 pilot evaluated the hybrid review CLI `@alibaba-group/open-code-review` (OCR) in delegation mode and measured precision 1.00 (6 true positives, 0 false positives) over 5 real merged firstmate PRs, with 0 tokens spent on the OCR side.
Delegation mode is deterministic on the tool side: `ocr delegate preview` selects reviewable files from a diff corpus, and `ocr delegate rule` resolves review rules; the hosting agent then performs the actual line-level reasoning with its existing runtime authentication, so no new credential and no LLM key on the OCR side are needed.

Nothing from OCR is installed in firstmate by this graduation.
When you want to use it, install the pinned CLI in a sandbox outside this repo, for example `npm install @alibaba-group/open-code-review@1.12.7`, point it at a read-only corpus or a PR diff, and run `ocr delegate preview` followed by `ocr delegate rule` to get the deterministic file selection and rule checklist before reviewing.
The pilot also recorded two limits to carry into any future adoption: the default exclusion list does not know about `*.test.sh`, so bash-first repos see their tests included as reviewable, and rule resolution for shell code yields only the generic checklist.
The future adoption path is a separate graduation decision that would integrate the delegation skeleton (`preview` + `rule`) into the fleet review flow, adding OCR's rule resolution and file selection on top of the coverage skeleton `fm-diff-assert.sh` already emits; until then, the coverage block and the assertions above are the adopted deterministic layer.
