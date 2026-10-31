**October30 · Voice0.22.6 installed locally:**
Reviewed clean release preserves recording gaps/converter tails and live ASR
clock alignment.424installed files match;13othermodules/40grant bytes exact,
SDK resources/entitlements retained. Native settings/Fn/model choices and four
older meetings remain. The owner clarified October 30 that the recording trial has NOT been run.
Earlier positive reports are superseded; live words, Pause/Resume, saving and
saved timing remain unverified. No programmatic
capture or shared-speech approval claim. [Delivery and limits](reports/meeting-end-to-end-2026-10-29/README.md).

**October29 · local meeting-timing source candidate (not installed):**
Separate input/output clocks preserve captured gaps, resampler tails and source
alignment through rotation/Resume. Backward clocks and format changes explicitly
refuse after preserving accepted tails; live ASR pads bounded short gaps.
Clean225Swift/15worker-policy checks pass; actual release workers retain all36
contiguous-case texts. Actual cached-human file/live speaker baseline is30.70%/
32.08%pooled DER, showing remaining missed activity. No new WER/live-recording or
installed quality claim; Voice0.22.5 remains installed. No SDK/cloud/capture/public
change. [Evidence and limits](reports/meeting-end-to-end-2026-10-29/README.md).

**October 28 · Voice 0.22.5 installed locally:**
Bounded per-source adaptive energy admission retains quieter MLX meeting speech;
original loud trigger, 350 ms pre-roll and explicit commit/gap resets remain.
Word-level uncertainty survives regrouping, preventing fabricated confident
speaker labels. Clean-source 215 Swift + 11 worker checks and six Python speaker
policy checks pass. Twelve cached read-speech clips/182 words: Parakeet13→2,
Nemotron9→4 errors, no clip regressions; six synthetic nonspeech controls emit no
words. Release reproduces debug; installed package/native Running verified.
Not broad WER/DER/live Teams or battery qualification. SDK working changes and
other13modules retained; no capture/cloud/public/default-model changes.
[Behavior and limits](docs/MEETING-QUIET-SPEECH-2026-10-28.md).

**October 28 · Voice 0.22.4 installed locally:**
Bounded 350 ms per-source pre-onset audio reaches live MLX ASR once; explicit
turn boundaries and discontinuities discard it. Word-timed speaker attribution
excludes ASR gaps while preserving overlap uncertainty/manual corrections.
213 Swift + five worker checks pass; final release helpers reproduce 23→13
Parakeet and17→9 Nemotron word errors on12 cached clean/quiet paired read-speech
clips (182 words). Not a live meeting/WER/DER population claim. Very quiet distant
speech remains a known gap. Signed package/installed Running/424 exact files and
other13module continuity verified; no capture/cloud/public/SDK/default changes.
[Behavior and limits](docs/MEETING-COVERAGE-2026-10-28.md).

**October 27 · local 0.22.3 meeting-action candidate (uninstalled):**
Original-transcript English commitment reconciliation supplies current
owner/deadline/status, with reassignment/cancellation source links and explicit
Needs review/limited-language coverage. Local overview generation remains Apple
and now has real array-count constraints. Eight authored pipeline cases pass
(vs6/8 prior); two model-driven action candidates rejected. Full206Swift checks
and web source/state checks pass. No install, SDK, cloud, capture, grants or
public changes. [Behavior and limits](docs/MEETING-ACTION-NOTES.md).

**October 27 · local speaker-opening continuity follow-up (uninstalled):**
The same 0.22.2 source candidate now attaches an eligible speaker queue before
capture, reuses it through delayed preparation/Pause/Resume, and prevents launch
after Stop during the shared-model wait. The shared 2,048,000-byte bound remains;
overflow retains audio and refuses final attribution so saved analysis can run.
186 Swift checks pass (all prior180 plus6), and ModuleApp builds locally. Existing
40ms diarization policy/summarizer/defaults/installed0.22.1/SDK retained; no models,
live capture, signing, install or publication. [Evidence and limits](reports/meeting-speaker-continuity-2026-10-27/README.md).

**October 21 · local 0.22.2 candidate:** opening audio queues before recognition
preparation; 40 ms speaker edge timing reduces missed speaker time by 13.49%
across three short public AMI windows. 180 Swift / nine worker tests, independent
NIST, actual isolated live/file workers and signed package/ZIP checks pass.
Manual corrections retain their labels. Three notes-generation candidates
regressed and were excluded; the existing summarizer stays unchanged. Not
installed, notarized or published; host/SDK, accounts and grants unchanged.
[Evidence and limits](../NeroNook/reports/voice-meeting-reliability-2026-10-21/README.md).

**October 20 · Voice 0.22.1 installed locally:** meeting notes open as readable
summary/decisions and source-linked action cards. Editing stays behind disclosures;
old/manual notes retain their editor. Current-commitments generation is included;
a stricter typed-extraction experiment regressed and was excluded. Shared SDK
Light/Dark/compact review, 177 Swift checks, web/protocol checks and installed
Running/signature/continuity pass. No speaker model/default or public changes.
[Delivery and limitations](../NeroNook/reports/voice-meeting-actions-2026-10-20/README.md).

**October 20 · Voice 0.22.0 installed locally:** physical TextEdit shortcut,
replacement and immediate Undo pass. Specific pre-write failures support explicit
retry; uncertain writes do not. Chrome/Electron acceptance remains incomplete.
177 Swift checks, web regressions, signed protocol and installed Running status
pass. Preferences, placement and 36 access definitions are retained.
[Installed evidence](../NeroNook/reports/voice-022-acceptance-2026-10-20/README.md).
Meeting-note quality improvements and a measured human-speaker baseline are
separate uninstalled work: [results](../NeroNook/reports/voice-meeting-quality-2026-10-20/README.md).

# Nero Voice
Independent native voice plugin. Read README.md. Keep microphone, recognition, hotkeys and speech synthesis here, not in NeroNook. Use only the shared SDK for optional conversational providers; no account/token imports. Local Apple Speech first; no silent cloud fallback. The owner authorized Meetings, including explicit microphone/system-audio recording, saved audio and diarization; see docs/MEETINGS.md. No ambient recording or wake word. Start recording only from a direct user control. Preserve editable transcript review before copying/sending. Bound audio queues and duration, serialize lifecycle, reject late callbacks and stop on shutdown/sleep. Maintain OmniVoice provenance. No automatic subagent delegation.
