# Deterministic diff review layer

Fleet PR review has a deterministic, LLM-free layer that asserts structural properties of a task diff before or alongside agent reasoning, and hands the reviewer a line-anchored map of everything the diff touches.
It catches the two signature coding-agent failure modes, claim-without-diff and no-op-with-diff, plus two diff-shape guards, at zero token cost and with fully reproducible verdicts.
The script is `bin/fm-diff-review.sh`; its header and `--help` own the exact flags and parsing semantics.
This layer is optional: the no-mistakes pipeline stays the owner of validation, and merge authority is unchanged.

## Where it came from

The assertions are a port of the two deterministic graders from Duolingo's engineering blog "How Duolingo Built a Production-Ready AI Agent Platform" (2026-08-04), via the `pavani06/fleet-lab` graduation experiments.
The lab evidence (DEC-002a) measured 12/12 detection of failed synthetic cases and 0 false positives across 10 real merged firstmate PRs.
The port keeps the validated diff-parsing semantics exactly, and `tests/fm-diff-review.test.sh` pins them.

What the port is faithful to is that measured property - zero false positives - not the literal phrase lists of the lab source.
The lab classified claims by bare substring, which reads "unresolved" as resolve, "prefix" as fix and "dispatch" as patch, so firstmate matches claim phrases on word boundaries with explicit inflection suffixes instead, and treats an explicit negation ("no code change was warranted") as a no-change claim even when it also carries a positive word.
Because a stem now covers its own inflections, the lab lists' redundant entries are gone rather than repeated; the script header records the divergence.

## Line-anchored coverage

Every run first prints a `COVERAGE` block that enumerates each hunk of the diff with its file and the old/new line ranges from its `@@` header:

```
COVERAGE (hunks=2)
  bin/one.sh @@ -1,2 +1,3 @@
  docs/two.md @@ -7 +7,2 @@
```

This is the deterministic half of the DEC-003 line-by-line objective: the reviewing agent consumes the block as the guaranteed surface it has to cover, so no touched region of the diff goes unexamined because the agent never noticed it.
Producing the skeleton needs nothing beyond the diff itself - no CLI, no dependency, no tokens.

## The four assertions

- Claim consistency: a claim announcing a change over an empty diff fails, and a no-change claim over a real diff fails.
  A claim that classifies as neither (most ordinary prose) is never a failure, which is what keeps the grader free of false positives.
- Forbidden paths: any changed file under a `--forbid-path` prefix fails, for example to notice a worker that touched `state/` or `.env`.
- File limit: more than `--max-files` changed files fails.

## Running it

The diff is read from a file or from standard input, so any PR diff source works.

```sh
git diff main...HEAD | bin/fm-diff-review.sh --diff - --claim "fixed the flaky login test" --forbid-path state/ --max-files 20
gh pr diff 1234 > /tmp/pr.diff
bin/fm-diff-review.sh --diff /tmp/pr.diff --claim "fixed the flaky login test" --forbid-path state/
```

Exit codes: 0 all assertions passed, 1 at least one failed, 2 usage or read error.
At least one assertion must be requested, because a review run with nothing to assert is a caller mistake, and every flag requires a non-empty value, because an empty one would otherwise silently disable the assertion it asked for.
A diff the layer cannot read is a read error, never a PASS: a verdict is only worth its input.

## Where it fits in the fleet PR flow

Run it at the validation point, before or alongside the agent's own review of the diff.
It is an input to review, not a gate: this graduation adds no required check, changes no merge authority, and does not modify `fm-pr-check.sh` or `fm-pr-merge.sh`.
A worker or reviewer can cite the verdict in a PR body or task report; a FAIL line names each failure directly.

## open-code-review (OCR) in delegation mode - documented, not installed

The line-anchored coverage above already delivers the DEC-003 objective without any new dependency; what follows is the evaluated CLI path, recorded as a possible future upgrade only.

The lab's DEC-003 pilot evaluated the hybrid review CLI `@alibaba-group/open-code-review` (OCR) in delegation mode and measured precision 1.00 (6 true positives, 0 false positives) over 5 real merged firstmate PRs, with 0 tokens spent on the OCR side.
Delegation mode is deterministic on the tool side: `ocr delegate preview` selects reviewable files from a diff corpus, and `ocr delegate rule` resolves review rules; the hosting agent then performs the actual line-level reasoning with its existing runtime authentication, so no new credential and no LLM key on the OCR side are needed.

Nothing from OCR is installed in firstmate by this graduation.
When you want to use it, install the pinned CLI in a sandbox outside this repo, for example `npm install @alibaba-group/open-code-review@1.12.7`, point it at a read-only corpus or a PR diff, and run `ocr delegate preview` followed by `ocr delegate rule` to get the deterministic file selection and rule checklist before reviewing.
The pilot also recorded two limits to carry into any future adoption: the default exclusion list does not know about `*.test.sh`, so bash-first repos see their tests included as reviewable, and rule resolution for shell code yields only the generic checklist.
The future adoption path is a separate graduation decision that would integrate the delegation skeleton (`preview` + `rule`) into the fleet review flow, adding OCR's rule resolution and file selection on top of the coverage skeleton `fm-diff-review.sh` already emits; until then, the coverage block and the assertions above are the adopted deterministic layer.
