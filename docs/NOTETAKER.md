**October 13 · saved meeting chat:** Voice 0.14.1 / Agent 0.3.4 persist
per-recording and library conversations. Native restart/follow-up/two-meeting
comparison, 9.2-second original source navigation without playback, changed
source rejection and New/Restore pass with authored synthetic text. 68 Voice
and 25 Agent tests pass; all four original recordings/19 files are unchanged.
[Usage and limits](MEETING-CHAT.md) · [receipts](../reports/meeting-chat-2026-10-13/README.md).

**October 13 · Voice 0.13.1:** explicit read-only calendar occurrence links
share a recording, every transcript and its notebook. Native fixture identity /
reschedule / missing / unlink checks and original-library preservation pass.
Google and Mac Calendar reads completed for an empty selected day; populated
personal-event acceptance, reminders and Join remain open.
[Usage](CALENDAR-MEETINGS.md) · [receipts](../reports/calendar-links-2026-10-13/README.md).

**October 13 · cited meeting answers:** Voice 0.12.3 / Agent 0.3.3 add
explicit transcript-only questions, bounded evidence preview, inspected source
links and cancellation. [Usage](ASK-MEETING.md) · [verified evidence](../reports/ask-meeting-2026-10-13/README.md).
No capture or notebook/ASR default is changed by this feature. Cross-meeting chat,
Explicit calendar links are installed in 0.13.1; populated personal-event
linkage and real-meeting answer accuracy remain open.

# Meeting notebooks · Voice 0.10.2

Meetings remains an explicit local recording feature, separate from hotkey
dictation and Agent. Record a selected microphone, app audio group or all-system
audio. Apple, Nemotron 3.5 and Parakeet are shared with dictation; saved
transcripts/corrections remain separate per recognizer. Speaker analysis runs
sequentially. This delivery does not add ambient recording or cloud uploads.

## New notebook

Each saved meeting has Transcript, My thoughts and Summary & actions tabs.
The notebook is a separate versioned `notebook.json`, not a replacement for the
original transcript. Personal thoughts, summary, decisions and action items are
editable fields, each bounded to 2 KiB UTF-8. Save notes writes atomically with
private permissions; selected-meeting identity and normal-file checks apply.
Regeneration preserves My thoughts and asks before replacing existing draft
fields. Unsaved edits block tab/meeting changes and New/Delete. Closing the
window is not yet a recovery/autosave guarantee; save before closing.

Copy notes excludes My thoughts by default. Include My thoughts is an explicit
choice. Library search checks titles, notes, names and all recognizer variants
among the newest 500 meetings. SDK search examines the selected recognizer and
excludes personal thoughts. Larger libraries need indexing/pagination work.

## Local summary draft

Create local summary uses Apple's on-device FoundationModels, only when Apple
Intelligence is available. No audio or text is sent to a cloud provider. Manual
notes work when that model is unavailable. It does not load a neural TTS model,
and starting a summary is blocked during dictation, speech or other meeting
processing.

Generated statements cite integer transcript source IDs. Voice renders their
timestamps from the saved source clock, checks source bounds and rejects ISO
calendar dates absent from the cited utterance. Summary source provider/revision
and transcript digest are retained. Corrections or speaker renames make that
provenance stale. These checks are not proof that every generated statement is
entailed: facts, completeness, owners and dates still require human review.

Input is bounded to 32 sections of 6 KiB, then reduced in isolated short model
sessions. A turn over 6 KiB or a final notebook field over 2 KiB fails without
overwriting prior notes. Every model request has a 30-second deadline; Stop,
sleep/lock or shutdown cancel the owned operation. A timed-out or cancelled
model request disables new summary attempts until Voice restarts, preventing
another request from overlapping a model worker that has not responded to
cancellation. Hierarchical reduction can omit detail; real long-meeting quality
has not been accepted. No calendar-date inference is made from elapsed clocks.

The first 24-second synthetic fixture failed: a freeform draft invented a date
and omitted a review task. Its receipt is preserved. Source-ID output retained
both tasks in the corrected check and native installed generation. Owner
attribution still needs review; this is not a scored factuality or completeness
benchmark.

## Permission-scoped text tools

`speak_text` is separate from `search_meetings` and `read_meeting`. Granting speech
does not expose the meeting library. No library grant was enabled as part of this
delivery. A permitted consumer can search at most six matching meetings per
request and page text in 2 KiB responses. `read_meeting` requires a meeting UUID,
integer character offset and explicit `personal_notes` boolean; false excludes
My thoughts. It returns `next_offset` and `has_more`. No audio bytes or local
filesystem paths are exported. A read spans the current selected recognizer;
multiple pages are not an immutable snapshot and must be reread after edits.

Agent's additional per-message Use Nook context is required for its model to use
these tools. Granting local routing alone does not authorize cloud disclosure.
A source-cited Ask meeting interface and external MCP server remain follow-ups.

[Current Wispr comparison and queue](../../NeroNook/docs/WISPR-FEATURE-REVIEW.md)
· [Evidence](../reports/shared-speech-notetaker-2026-10-13/README.md).
