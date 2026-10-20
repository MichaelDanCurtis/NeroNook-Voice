# Saved meeting conversations · Voice 0.14.1

Select a recording in **Nero Voice → Meetings → Ask this meeting**. Type a
question, choose **Preview excerpt**, inspect the selected text and recent chat
context, then choose **Send excerpt & ask**. Questions, answers and original
source references are saved on this Mac. Choose that recording again after
switching meetings or restarting Voice to return to its chat.

For questions across recordings, choose **Ask saved meetings** above the meeting
card, or **Saved meetings** in the chat. Leave **Meeting title filter** empty to
search saved recordings, or enter a title phrase to narrow them. Preview shows
how many recordings were searched and which excerpts fit. Each answer's source
buttons include the recording name, date and transcript clock. Click one to
open the original recording, recognizer and live/refined variant, highlight the
passage and position playback; it does not start playing. **Ask saved meetings**
returns to the library conversation. Selecting a library recording manually
switches back to that recording's own chat.

Follow-up questions include up to four recent completed exchanges, bounded to
2 KiB; individual context may be shortened to fit. The exact transmitted
context is visible in the preview. Historical answers help resolve references,
but are never transcript evidence: each new answer must cite current selected
sources. **Review sent excerpt** reopens a saved turn's exact disclosure. Send
asks again only after rechecking its original sources. New questions create new
entries; no automatic retry or resend occurs on reopening a chat.

**Earlier exchanges / Latest exchanges** page the saved conversation. **New
chat** starts fresh and keeps one previous conversation. **Restore previous**
swaps it back. Each recording and the library have their own current / previous
chat. Up to 50 exchanges / 2 MB per current conversation are retained; at the
limit, start a new chat. Interrupted pending questions are marked interrupted
on reopening; already-sent text cannot be recalled by Stop.

## Privacy and independent products

Voice owns the chat and transcript retrieval. Agent owns its separate managed
ChatGPT account, with no microphone/audio access. The optional generic SDK
**answer_evidence_chat** action has its own grant; allow it for Voice in Nook
Settings → Modules. Existing one-question providers can still be used, but
cannot receive follow-up context. The old cited-answer action remains unchanged.
No host update or implementation dependency between plugins is required.

Typing, opening, locally searching and previewing send nothing to an assistant.
Send shares only the previewed transcript excerpts, recording/date/speaker
labels, the question and visible recent chat. Audio, My thoughts, derived notes,
calendar details, other Agent conversations and Mac tools are excluded. Agent
and Fuego meeting-library read permissions remain off; this adapter requires no
library enumeration capability in the assistant. Local calendar attachments and
all recording/transcript/notebook files remain independent and untouched.

## Retrieval and acceptance limits

Library questions use deterministic keyword matching plus conversational
neighbors, with diversity across matching recordings. This is not semantic or
exhaustive reasoning over an unlimited library. A preferred recognizer is used
when available; otherwise another saved transcript can be selected, retaining
its exact recognizer/live identity. Within each recognizer, saved refined text is preferred to a live
draft. Missing/corrupt/oversized transcripts are skipped, with incomplete coverage
reported. Recording/paused sessions are excluded from library queries; the
current meeting can be asked separately using its settled live words.

The local scan is capped at 500 saved recordings, 64 MB of transcript files and
100,000 turns. The evidence has at most 32 excerpts and 8 KB of source JSON.
Questions are at most 1 KB; answers are at most 2 KB. A preview may therefore
cover selected excerpts rather than a full meeting/library. Inspect it before
sending. The assistant can say it has insufficient evidence.

Correct source IDs and fingerprints ensure navigation, not factual entailment.
ASR errors, missed keyword matches, ambiguous follow-ups and AI interpretations
still need review. A changed or deleted source cannot be silently redirected to
another passage. The historical answer and its original excerpt remain saved,
but source navigation fails explicitly. Public distribution, long/noisy meeting
quality and sustained-resource acceptance remain separate work.

[Shared SDK](../../NeroNook/SDK/EVIDENCE-ANSWERS.md) ·
[delivery evidence](../reports/meeting-chat-2026-10-13/README.md).
