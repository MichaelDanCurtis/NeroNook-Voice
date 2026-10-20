**October 15 · Voice 0.18.0, Teams offers and per-source speakers:** installed
locally on host 0.32.0. Native Teams and supported browser/PWA call controls can
produce a focus-free **Start notes / Not now** offer. Detection never records;
browser capture explicitly includes other tabs. Meetings exposes both offer and
speaker switches directly. Nemotron 3 separates people within each Room/Call
track: live provisional labels with Apple Speech, or a saved-audio pass after
MLX recognition, keeping one resident MLX model. Manual names/corrections and
original live/refined files are preserved. 100 Swift checks pass, and real local
inference identifies two authored synthetic voices on each of two timed tracks.
Actual Teams desktop/browser calls, echo, overlap and long sessions remain
acceptance gates. [Usage and limits](TEAMS-AND-SPEAKERS.md) ·
[local evidence](../../NeroNook/reports/teams-speakers-2026-10-15/README.md).
No public release before host 0.35.0.

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

# Live meetings · Voice 0.11.2

In Nero Voice → Meetings, keep Live transcript checked, select your speech model
and microphone/call source, then Start recording. Apple Speech remains the fresh
installation default; existing choices are kept. Prepared Nemotron streams words;
Parakeet updates at pauses or every ten seconds. A model that is not prepared
leaves an explicitly labeled audio-only recording. No cloud fallback.

Settled words and a lighter in-progress tail appear in the meeting card. Pause /
Resume / Stop retain the shared audio clock. Room and Call identify separate audio sources. Voice 0.18 can label people
within each source live with Apple Speech and after Stop with MLX ASR. Manual
names and a saved-audio Identify speakers pass remain available.
Refine saved audio creates a separate provider transcript; Original live draft
and Refined transcript let you switch without overwriting the other file.

What did I miss works during recording and on saved transcripts. Choose the last
30 seconds, two minutes or five minutes. It shows locally selected key moments
using the exact transcript wording and clocks. Only settled words enter the
snapshot; later speech continues independently. Up to six excerpts are selected,
with visible ellipses for long text. A displayed range/context-limit notice
states coverage. It can omit important turns or quote recognition errors; use
the full transcript/audio to review. It needs Apple Intelligence enabled.

Live recognition failure retains audio and settled text. Transcribe the saved
recording to recover missed words. A local summary/catch-up cancellation or
nonresponse may require restarting Voice's local model circuit before retrying;
recording remains independent. There is no ambient capture or automatic cloud
upload. Existing paged SDK meeting reads target refined transcripts; richer live
source/citation support belongs to the upcoming Ask this meeting slice.

[Checks and remaining real-call gates](../reports/live-meetings-2026-10-13/README.md).
