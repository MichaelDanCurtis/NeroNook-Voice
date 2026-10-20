# Teams meeting notes and speakers · Voice 0.18

Owner-authorized October 15, 2026. Keep host 0.32 and the independent Voice build
separate; all delivery is local until at least host 0.35. No cloud audio, bots,
account imports or new training. Preserve Fn dictation and the existing library.

## Use it

In Nero Voice → Meetings, leave **Offer notes for Teams calls** and **Separate
room & call speakers** enabled. Prepare speakers once if asked. Existing model
choices are retained; Apple Speech is the new-install default. Apple Speech can
show provisional people labels while recording. With Nemotron/Parakeet ASR, labels
are added after Stop so only one MLX model runs at once.

Join your Teams desktop or web/PWA call. A small nonactivating card offers
**Start notes** and **Not now**. It expires after 35 seconds; open Meetings to
start manually if you miss it. Not now suppresses another prompt in that call.
Start notes creates a new recording, using the chosen microphone and the exact
application source shown. It never inherits an old meeting's calendar link.
Browser audio includes other tabs; close/mute unrelated playback or use native
Teams for app-level isolation. The recognition/detection controls do not join,
leave, message or control Teams. Stop & save remains explicit.

Room speaker 1/2 and Call speaker 1/2 are anonymous per-source labels, not names.
Review transcript labels and rename speakers yourself. Timed words can split a
sentence at a detected turn; uncertain/overlapping words can stay unassigned.
A person's room voice and call voice are not automatically merged. Headphones
reduce call echo leaking into the room microphone. Identify speakers can recheck
a saved live or refined transcript; your text edits/manual names are protected.
Turning separation off skips automatic analysis; the explicit Identify action
remains available.

## Implementation contract

Detect Teams call activity from bounded macOS process/audio metadata and call
controls, not a running-app test. Offer Start notes / Not now without taking the
editor's focus. Starting is explicit and shows its audio scope: microphone plus
Teams application audio. A browser/PWA source must disclose browser-wide audio;
never claim a Core Audio app tap isolates one browser tab. Device test/prejoin,
notifications, mute/unmute, missing accessibility and helper replacement need
separate qualification. Suppress repeats in the same call and retire stale offers.

Keep microphone and call tracks on their existing common clock. Nemotron 3
identifies up to eight anonymous speakers within each track. Room and Call
speaker labels are independent; no identity is inferred from track, calendar or
voice appearance. Preserve uncertain/overlapping speech, original words and
manual text/name corrections. Do not conflate echo with a proven new person.

Offer live provisional speaker attribution with Apple Speech using one shared
Nemotron speaker model and distinct streaming state per source. Preserve the
speaker session across pause/resume. For a selected MLX ASR, perform speaker
analysis after ASR exits, keeping one resident MLX model. Bound live queues;
failure of optional live attribution must leave recording intact and offer a
saved-audio pass. Final analysis is cancellable and retains prior source text.

## Acceptance

- Pure state tests: stable-call debounce, dismissal, stale acceptance, call end,
  mute/reconnect, busy/sleep and independent source/identity separation.
- Native process observation is metadata-only; fixtures do not prove an actual
  Teams call. Start notes cannot capture before its explicit button is selected.
- Real local speaker inference on authored multi-voice, two-track audio; verify
  word timing, source clocks, speaker changes and final flush. Synthetic results
  do not establish real-meeting accuracy or echo rejection.
- Native offer, dismiss/start, meeting settings/status, controls, cancel and Fn
  regression. Preserve all original meeting files and other module records.
- Build/package/sign independent Voice, verify installed bytes and record actual
  versus pending native Teams/browser, overlap, long-session and accuracy checks.

Primary references: [Apple process input metadata](https://developer.apple.com/documentation/coreaudio/kaudioprocesspropertyisrunninginput),
[Apple speech timing attributes](https://developer.apple.com/documentation/speech/speechtranscriber/resultattributeoption/audiotimerange),
[NVIDIA Nemotron 3](https://huggingface.co/nvidia/Nemotron-3-Diarization),
[MLX model](https://huggingface.co/mlx-community/Nemotron-3-Diarization).

## Qualification and limits · October 15

100 Swift tests and the signed modern/legacy-caption protocol checks pass. A
29.41-second authored Samantha/Daniel file was fed to both synthetic sources,
with a 0.25-second source offset: 24 speaker updates, two speakers per source,
and 20 word-aligned utterances. This exercises actual local Nemotron streaming,
Apple alignment, flush and source timing. It is not a diarization accuracy score.
Native Start/Not now previews and installed preference controls were checked.
A separate native Nemotron-ASR → Stop → speaker-pass fixture saved 14 timed turns
with two people per source; manual naming survived an explicit re-analysis.
A whitespace-only timing handoff failure was reproduced and corrected without
changing recognition text or fabricating timestamps.

Real desktop and browser calls remain unverified. Browser/PWA detection relies
on an accessible Teams page and call controls; hidden/background tabs, non-English
controls without stable IDs, prejoin/device tests and Teams UI updates need
qualification. The native microphone-use fallback is labelled lower confidence;
it does not silently record. No Accessibility permission means browser detection
may be unavailable; manual meeting capture still works. Observation scans only
bounded window/control metadata, not messages, form values or participant names.

A selected app tap groups its current Core Audio helper processes by their actual
outer application bundle. Replacement audio helpers are not dynamically reattached
mid-recording. Capture gaps stop safely and retain audio; route/helper changes and
call reconnect need physical acceptance. Real echo/overlap, speaker drift, longer
calls, sleep/recovery and broader hardware remain release gates. This slice adds
no automatic call-end stopping, participant-name matching or native Teams bot.

[Local delivery receipts](../../NeroNook/reports/teams-speakers-2026-10-15/README.md).
