**October 13 · persistent and cross-meeting chat:** Voice 0.14.1 / Agent 0.3.4
save questions and answers locally and add Ask saved meetings. Source buttons
restore the original recording and transcript variant. Follow-up context is
previewed explicitly. [Current usage and limits](MEETING-CHAT.md).

The single-question 0.12.3 description below is historical; its transient-chat
and single-meeting limitations are superseded by the new delivery.

# Ask this meeting

Choose a saved meeting (or a recording with settled live words), then **Ask
this meeting**. Type a question and choose **Preview excerpt**. The card shows
the recognizer, live/refined source and whether the full settled transcript fits.
Use **Inspect text to be sent** to read the exact included passages. Choose the
permitted assistant and **Send excerpt & ask**. Nothing is sent on typing,
previewing, recording, or opening a meeting.

The supplied material is only recognized/corrected transcript text with source
labels. Audio, My thoughts, derived summaries, other meetings, app/screen context
and previous Agent chats are excluded. The initial provider is Nero Agent using
its own managed ChatGPT account. It has no tools or action proposals for this
request. Enable just its cited-answer action for Voice in Nook Settings → Modules;
no meeting-library read permission is needed in the other direction. The host,
Voice and Agent remain independent.

Each answer statement has timestamped source buttons. A saved-meeting citation
restores the exact recognizer and live/refined variant, opens the correct page,
highlights its passage and moves the playback cursor without starting audio.
During recording, it opens and highlights the frozen excerpt in the question
panel; it does not interrupt capture or live follow-scroll. A changed/deleted
passage is rejected rather than linked to different words. Live appends do not
invalidate unchanged passages. Inspect the text: a valid source ID is not a
guarantee that the model's interpretation is correct, and ASR errors remain.

**Stop** cancels the pending SDK request. Late, revoked, malformed or mismatched
results are ignored/rejected. Text already delivered to ChatGPT cannot be
recalled by Stop. Questions/answers are transient, cleared on meeting change or
Voice restart; notebooks and transcripts are not overwritten.

## Bounds and remaining work

- A question is at most 1 KiB; evidence has at most eight 2 KiB transport pages.
  Small meetings fit in full. Larger ones use deterministic word matching and
  immediate neighboring passages, up to 32 excerpts. Coverage is visible.
- Long turns are split into exact UTF-8-safe excerpts; their labels say excerpt.
  This is bounded lexical retrieval, not a semantic whole-library search.
- Answers fit 2 KiB, require known source IDs, and may explicitly report
  insufficient evidence. No automatic retry, model switch or cloud fallback.
- One question is active at a time. This version does not keep a multi-turn
  meeting chat or search across multiple meetings.
- Real ChatGPT + native Nook checks use authored synthetic text. Long, noisy,
  multilingual and real-meeting answer quality remains owner acceptance.

[Shared SDK](../../NeroNook/SDK/EVIDENCE-ANSWERS.md) · [delivery evidence](../reports/ask-meeting-2026-10-13/README.md).
