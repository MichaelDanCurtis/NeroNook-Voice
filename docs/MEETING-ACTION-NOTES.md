# Meeting action drafts

The local 0.22.3 development candidate separates task resolution from the AI
overview. Tasks are reconciled chronologically against the **original corrected
transcript**, so a generated interim summary cannot drop a reassignment or
resurrect an earlier cancelled promise.

## Current behavior

- Clear English `I will`, `I'll`, `We will` and user-named-person commitments
  supply task candidates. Named owners come from an explicit name or the
  utterance's user-assigned speaker name. Room/call tracks and generic speaker
  labels never establish a person's identity.
- Explicit takeovers update the owner; accepted `Friday replaces Monday for
  the board pack` revisions update that task's deadline. Different tasks retain
  separate dates. Missing dates remain **No deadline stated**.
- Explicit cancellations leave the active list and remain visible as
  **Cancelled**, with original and change sources. A former owner's withdrawal
  does not cancel work another person took over. A new explicit promise can
  reopen a cancelled task without borrowing its old deadline.
- Conflicting owners, ambiguous cancellation targets, conditional/reported
  promises and unsupported wording remain **Needs review**. The interface states
  the limited English scope even when no automatic tasks were found. An empty
  list is not proof that a meeting contained no commitments.
- Cards show owner/deadline and independently navigable original/change turns.
  Transcript corrections, renaming or source changes invalidate source links.
  Editing the action list clears its generated metadata and citations.
- Old/manual notebooks retain their plain action list. Optional resolution
  metadata round-trips in the existing notebook format; older readers can still
  read active action text, but do not display the new change metadata.

Apple's on-device Foundation Models engine still creates the overview and agreed
decisions. Generation now has actual array-count constraints rather than only
prose requests. No model, speech default, SDK, cloud fallback, account or grant
was changed. Capture and agent execution remain separate from notes.

## Local checks

- Eight authored cases were frozen before the comparison. The prior pipeline
  passed **6/8**: it omitted a revised deadline and failed the longer cancellation
  case. The selected pipeline generated **8/8** and passed the declared task,
  owner, per-task deadline, cancellation and source checks. Gold fields were
  excluded by the tool's input decoding.
- Two more elaborate model-driven structured-action candidates regressed and
  were rejected. Their local source/outputs remain retained; neither was
  installed or silently used as fallback.
- The full Swift suite passes **206 tests**: prior 186 plus 20 action-resolution
  and reconciliation tests. Tests cover source-field refusal, persistence,
  manual edits, stale links, ambiguous/conditional work, reopening, shared-owner
  uncertainty and cancellation without erasing a takeover. A first full attempt
  caught a conditional consequent entering the task title; a clause-boundary
  fix passes the unchanged assertion, with the failed log retained.
- Native report-local WebKit review checked Dark and compact Light cards,
  current owner/deadline, cancelled styling and original/change source-button
  events. This was a nonpersistent authored renderer, not live meeting capture
  or installed UI acceptance. JavaScript checks cover stale/busy/manual-edit
  guards, legacy cards, each source, and limited-language disclosure.

The cases are development data after inspection, not a representative accuracy
benchmark or untouched holdout. WER/DER, real Teams, noise, accents, multilingual
task parsing, arbitrary coreference, implied deadlines, sarcasm, broad named-party
resolution and long-session product acceptance remain unqualified. The English
rules deliberately prefer review over inference; they do not establish semantic
truth. Recognition errors and unsupported forms can still omit or misinterpret
work; inspect the original transcript before relying on important assignments.

The existing 12-task, 2 KB-per-notes-field, 32-section and bounded original-evidence
limits remain explicit refusals rather than truncation. A task retains up to five
relevant original/current field/change sources; the full history remains in the
transcript. Nothing sends an email, creates an external task or invokes an agent.

## Reproduce locally

```sh
swift test
node scripts/check-meeting-view.js
swift run MeetingQualityCheck Tests/Fixtures/meeting-action-cases.json /tmp/nero-notes-new-results
python3 scripts/check-meeting-actions.py Tests/Fixtures/meeting-action-cases.json /tmp/nero-notes-new-results
```

The model check requires Apple Intelligence available on this Mac. Use a fresh
output directory; the probe refuses overwriting results and does not record audio
or read the user's meeting store. Detailed local evidence is under
`reports/meeting-action-evidence-2026-10-27` (not distributed).

Builds remain local. No installed app, public release, catalog, download,
notarization or Fuego deployment is part of this change.
