**October 20 · Voice 0.22.0 installed locally:** physical TextEdit shortcut,
replacement and immediate Undo pass. Specific pre-write failures support explicit
retry; uncertain writes do not. Chrome/Electron acceptance remains incomplete.
177 Swift checks, web regressions, signed protocol and installed Running status
pass. Preferences, placement and 36 access definitions are retained.
[Installed evidence](../../NeroNook/reports/voice-022-acceptance-2026-10-20/README.md).
Meeting-note quality improvements and a measured human-speaker baseline are
separate uninstalled work: [results](../../NeroNook/reports/voice-meeting-quality-2026-10-20/README.md).

## October 19 · structured meeting evidence source candidate

Optional per-item source links survive notebook reopen, reject transcript/name/clock/identity changes, and are removed when their editable category changes. Old notebooks decode without migration. Six source cards per page keep the payload bounded. Combined `swift test` passes 161 tests with zero failures (including four concurrent expression checks); `swift build` and meeting web regression pass. Authored span attribution improves 6/8 to 8/8 after unique interval coverage replaces duplicate summation; this is not natural-speech DER/JER or a model-quality benchmark.

Disposable nonpersistent native WebKit review passes exact source event and stale-control checks, with inspected dark/stale/light rendering. Actual host backend click, owner acceptance, semantic note support/completeness, natural speaker separation and real selected-text editing remain separate. No installed app, preference, grant, Fn path or account changed. [Full source evidence and limitations](../../NeroNook/reports/voice-improvement-2026-10-19/README.md).

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

## October 13 · app styles, snippets and opt-in history

Voice 0.16.3 is installed. 84 tests plus frontend/signed process checks pass.
Native app selection/save/reopen, exact snippet expansion, local Formal preview,
recognized/final history recovery without paste, off/erase and the larger window
are verified. History is restored off; owned test entries/rules/snippets removed.
All 20 meeting files and other installed plugins remain unchanged.
[Evidence](../reports/dictation-personalization-2026-10-13/README.md).
Physical hotkey/app/recognizer combinations and real ASR snippet trigger accuracy
remain separate acceptance. No real speech or field text was captured for QA.

## October 13 · folders and recording imports

Voice 0.15.1 is installed. Native folder/create/rename/move/removal/Undo,
owned WAV import, local Nemotron transcription, Play/Pause, folder-scoped Preview
and restart/reopen pass on the Ark. 76 tests and signed protocol/frontend checks
pass. The four original recordings and all 19 original files remain unchanged.
[Evidence](../reports/library-imports-2026-10-13/README.md).
Large real-world libraries, long/varied codecs, crash recovery and public signing
remain separate acceptance; no full Wispr/codec parity claim.

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

# Live meetings and catch-up 0.11.2 · October 13, 2026

Signed Voice 0.11.2 is installed; host, Agent and Fuego binaries are unchanged.
49 tests, actual file-fed three-provider/two-track runs, final audio flush,
recognition cancellation retaining audio, native synthetic live/catch-up and
installed primary-card selection/catch-up checks pass. Source excerpts remain
exact and time coverage is visible. Existing defaults, Voice 2 and hotkey are
retained. Shared speech-only grants are restored.

These checks use synthetic/public test files, not a new real call. Physical
microphone/Teams/Zoom, sustained/overlapping speech, long-session resources and
speaker/ASR/selection quality remain acceptance gates. [Exact evidence](../reports/live-meetings-2026-10-13/README.md).

Historical milestones follow.

---

# Shared Apple speech and notebooks 0.10.2 · October 13, 2026

Signed Voice 0.10.2 is installed; Agent 0.3.2 and Fuego Agent 0.1.1 consume the
shared SDK. Native Voice 2 Preview completes and Stop cancels preparation.
Settings retain Voice 2 / Warm & soft and the owner's Nemotron dictation,
Control–Option–V and Clean preferences. Fuego Read status completes and Stop
retires playback through the SDK. Fresh managed sign-in completed; Agent
0.3.2 with verified Codex 0.162.0 completed a real reply and its Read/Stop check.

All 39 Voice tests pass. Signed packaging/process checks and installed signatures
pass. A disposable synthetic meeting generated a local summary in the actual
native view; My thoughts saved, survived leaving/reopening the meeting and was
found by content search. Voice 0.10.2 also preserves the visible search query
across meeting changes; clearing it restores all four prior recordings. The
synthetic fixture is archived and recoverably removed from the live library. The initial model draft failed and was retained as
negative evidence. Corrected structured source output uses saved timestamps and
retains both tasks. This does not establish long-meeting completeness or owner
attribution. Human review, real microphone/system-audio calls, repeated playback,
power, output-route and sleep/cancellation acceptance remain open.

[Evidence and exact receipts](../reports/shared-speech-notetaker-2026-10-13/README.md)
· [Notebook limits](NOTETAKER.md). Historical milestones follow.

---

# Apple speech output 0.9.0 — October 13, 2026

Signed Voice 0.9.0 is installed and Running. Primary Dictate exposes Preview,
Voice settings, Read draft and Stop. Native settings select an available Apple
voice and Natural / Warm & soft / Lower & relaxed delivery. Ava Premium preview
start/completion, native Stop, Nook Read/Stop and saved voice/delivery after a
module restart are observed. 33 core/meeting tests and the signed process
protocol check pass; installed contents and strict signature verify.

The owner's existing dictation choice and shortcut are preserved. Test text is
cleared and Automatic/Natural defaults restored. Siri Voice 2 from the audition
is absent from this compiled app's catalog; no exact audition-voice claim is
made. First-use/repeated reliability, listening preference and power/physical
output-route checks remain open. Generic Agent/Fuego speech is next, not yet
installed. [Evidence, initial preview limitation and receipts](../reports/apple-speech-output-2026-10-13/README.md).

---

# Main-card speech models and Nemotron speakers 0.8.0 — September 28, 2026

Signed package `build/cafe.nero.plugin.voice-0.8.0-e84c84b3e507.app` is installed
through NeroNook's normal plugin review. The host remains 0.26.3. Apple Speech
is selected for both dictation and meetings. The main Dictate card now exposes
Apple Speech, Nemotron 3.5 MLX and Parakeet v3 MLX without opening settings.
Models download only through the explicit prepare control. Each provider keeps
its own meeting transcript. Nemotron 3 MLX replaces the optional speaker model.

Verified:

- The primary card renders in NeroNook on both displays. Apple → Nemotron →
  Apple selection works in the installed card. Native settings record a custom
  shortcut; Control–Option–V was restored afterward.
- All 31 Swift tests pass, including capture overflow/finalization, shared worker
  exclusion, provider transcript isolation, word-aligned speaker splitting and
  preservation of reviewed edits. Signed process handshake, custom-view SDK
  validation, snapshots, heartbeat and clean EOF pass.
- The signed native ASR worker transcribes a synthetic fixture with both MLX
  providers. The Swift streaming parent receives seven partial updates and a
  final Nemotron transcript from file-fed PCM. This is not microphone acceptance.
- The installed app prepared the models and transcribed the public 30-second
  speaker-demo fixture with Nemotron. It saved 72 aligned words in 13 utterances;
  eight utterances received two distinct generic speaker labels and five remained
  unassigned. The native UI shows both speaker names and unassigned speech.
  Speaker accuracy is not scored against ground truth. Switching back to Apple
  restores the pre-existing Apple transcript. The earlier trial Nemotron result
  is preserved as `transcript-nemotron-3.5-before-word-timing.json` in that public
  fixture's directory.
- The packaged isolated speaker worker runs from a private bundled runtime;
  the user needs no Python installation. Only one MLX worker may run at a time.
  The roughly 126 MB package fits the host's 128 MiB limit; deep/strict signature
  verification passes after execution. Python runs with `-I -B` to avoid modifying
  the signed app with bytecode caches.

The pinned Swift dependency has a narrowly scoped, source-hash-guarded local
patch exposing existing token timing as words. It changes neither decoding nor
weights. Upstream revision, this patch and app version form the provenance;
see [MODELS.md](MODELS.md) and [PROVENANCE.md](../PROVENANCE.md).

Limitations: fixtures do not establish real-microphone accuracy, long-meeting
reliability, measured end-to-end latency or fan/energy behavior. Parakeet provides
text after release; Nemotron supports partial dictation. Real hold/speak/release/
paste acceptance remains with the owner. No live microphone/system audio was
captured for these checks, and no recording was uploaded to a model service.

---

# Selectable meeting ASR 0.7.1 — September 28, 2026

Voice 0.7.1 adds an optional local Parakeet v3 transcription provider for
**saved meetings**. The user must choose it and explicitly prepare its pinned,
hash-verified 755 MB model. Apple Speech remains the selected default for
meetings and the only live dictation recognizer. Each meeting provider saves
its own editable transcript, so switching models does not overwrite Apple
Speech text or corrections. Canary, Nemotron 3 Diarization and Kokoro remain
evaluation candidates, not installed providers.

The signed package
`build/cafe.nero.plugin.voice-0.7.1-193520795932.app` is installed and
Running in NeroNook on both displays. The native Meetings page renders; its
provider picker shows Apple Speech and Parakeet. The installed app's explicit
Prepare control downloaded and verified the pinned model, after which
Transcribe became available. In the installed UI, Parakeet transcribed the
public 30-second speaker-demo fixture, saved timestamped phrases, and
reported completion. Returning to Apple Speech restored its previously saved
transcript; the two providers produced separate results. Independently, the
bundled signed Parakeet worker transcribed a locally generated speech fixture
into two timestamped phrases using a development copy of the pinned model.
The signed-process handshake, SDK
validation, three snapshots, background heartbeat and clean EOF pass. All 26
Voice Swift tests pass, including provider transcript isolation and reading an
older Apple transcript. The package's deep/strict signature verifies.

The public and synthetic fixtures do not establish recognition accuracy,
long-recording segmentation,
microphone quality, dictation reliability or the owner's physical
hold/speak/release/paste experience. No user recording or meeting audio was
sent to a model host. [Model details](MODELS.md).

---

# Dictation recovery 0.6.1 — September 28, 2026

The owner reported that 0.6.0 worked briefly, then stopped. Live NeroNook
Settings confirmed **Plugin stopped responding** and the Voice process was no
longer running. After a restart, the native Voice window showed a default-
microphone routing failure (`nope`, OSStatus 1852797029). These are observed
failure states; no crash report or stage-specific trace established which
operation blocked the process before the host's 15-second watchdog fired.

Voice 0.6.1 moves local language-model startup and polishing off the main
actor. A separate transport heartbeat tolerates brief Core Audio/model stalls,
but stops after 30 seconds without main-thread progress so a genuinely stuck
plugin still times out. Microphone setup skips an unnecessary device switch
when Core Audio already selected the requested input and retries a transient
route failure once with a fresh audio engine. A selected UID must still be an
input device. No transcript content is written to a diagnostic log.

The final signed package is
`build/cafe.nero.plugin.voice-0.6.1-eef370658213.app`. It is installed and
Running on both configured displays. Its installed executable matches the
signed candidate; native Dictate opens, and the prior in-memory draft was
restored after updating. All 25 Swift tests pass. The signed-process test
validates the modern handshake, SDK messages, three snapshots, a background
heartbeat, and clean EOF. A synthetic finalization/polish check still returns
“How are you doing?”. The initial 0.6.1 package candidate failed clean EOF
with a shutdown recursion; the shutdown guard was fixed before packaging and
installing this final candidate. No microphone capture or live paste is
claimed by those automated checks. Physical repeated hold/speak/release,
preview and paste acceptance remain open until the owner checks them.

---

# Hotkey dictation 0.6.0 — September 28, 2026

The signed independent Voice 0.6.0 package is installed through the host's
normal review and reports Running on Odyssey Ark and Built-in Retina Display.
NeroNook host 0.26.3 is installed and running with a generic negotiated
transient-caption surface below the Nook; Voice owns the caption content and
the host does not know about speech or editors. Native Voice settings show
Control–Option–V, Hold to talk, Clean output and Accessibility allowed. The
Dictate view presents Record draft here as a fallback and no Rewrite workflow.

The shortcut now works with Voice settings still open if the destination app
is frontmost. It captures that app and its focused window when available,
displays partial words without activating the Nook, then cleans the final
transcript and pastes into the same app. A changed app/window or a known secure
field prevents paste and keeps the draft. Clean and Formal optionally use the
available local Apple language model; Literal skips cleanup. No text is sent to
Nero Agent or another cloud service by this dictation path.

Verification: host and Voice `swift build`/`swift test`, both signed packages,
deep/strict signature checks, and signed Voice process handshake/SDK/snapshot/
clean EOF checks pass. A synthetic `say` audio fixture recognized “How are we
doing? I mean, how are you doing?” through the production capture/finalization
path; deterministic cleanup returned “How are you doing?”. The local Apple
language model is available on this Mac, and a short synthetic polish probe
completed. These checks do not establish physical microphone quality or the
desktop insertion outcome.

**Open owner acceptance:** in a disposable TextEdit document, place the caret,
hold Control–Option–V, say “How are we doing? I mean, how are you doing?”, then
release. Confirm that partial words appear below the Nook while speaking and
the corrected sentence appears at the caret afterward. Also check a second
editor, a changed-focus rejection and a Formal sample. If recognition or
insertion fails, the draft and Voice status can be inspected without sending
text anywhere else. Audio spoken during cold microphone preparation may be
missed; wait for Listening in this build.

---

# Hotkey dictation 0.5.1 — September 27, 2026

The owner narrowed Voice to one daily path: hotkey, speak, release, paste into
the active app. Dictate and Meetings are the only visible modes. Rewrite,
selection capture and its second shortcut have been removed from the active
app. Control–Option–V is the default hold-to-talk shortcut. Record draft here
remains a separate, clearly labelled review/copy fallback.

Version 0.5.1 removes the editor text/cursor-read requirement that caused the
earlier TextEdit capture failure. Shortcut start remembers the frontmost app;
release finishes local Apple Speech and sends Command–V to that same app. A
changed app or known password field stops insertion and preserves the draft.
The clipboard is restored when unchanged. Voice does not read back the editor
or claim that the target accepted the paste. The target app's Undo replaces
Voice's custom insertion undo.

The signed `build/cafe.nero.plugin.voice-0.5.1-e9686887180c.app` was installed
through NeroNook's normal update review and is Running on Odyssey Ark and the
Built-in Retina Display. The installed executable hash matches the built
candidate and its deep/strict signature verifies. All 23 Swift tests,
signed-process handshake/SDK/three-snapshot/clean-EOF check and the local
production speech fixture pass. The installed native Voice window shows only
Dictate and Meetings and the hold/speak/release instruction. The prior 0.5.0
settings showed Control–Option–V, Hold to talk and Accessibility allowed;
the update retained those preferences. No assistant call was made.

Physical microphone, global-hotkey delivery and the actual paste in a focused
editor are still awaiting an owner check. The synthetic speech fixture and
host Running state do not establish that end-to-end result.

---

# Rewrite capture update 0.4.3 — September 27, 2026

The owner reported that the timed Capture selection workflow failed and was
confusing. The 0.4.1 installed update fixed the Voice settings sheet, but its
frontmost-app focus fallback still did not capture the selected TextEdit
fixture through computer control. The 0.4.2 shortcut attempt exposed a second
UI problem: a capture from Dictate would reopen Dictate rather than Rewrite.
Version 0.4.3 removes the timed capture button and registers
Control–Option–R. It reads the focused editor before opening Voice, then
switches to Rewrite to show the captured passage. The shortcut can be turned
off in Voice settings; no global key listener or automatic assistant request
was added. The prior Ask ChatGPT grant was restored for this exact package.

The signed `build/cafe.nero.plugin.voice-0.4.3-796eba0fe3bd.app` is installed
and Running on both displays. All 25 Swift tests, release packaging, deep
strict signature check and signed-process handshake/SDK/snapshot/EOF check
pass. Native UI shows the shortcut enabled and ready, and the earlier
five-second capture button is gone. Computer control sends keyboard input
directly into TextEdit, so it cannot exercise the macOS global hotkey: its
attempt inserted a control character into the disposable fixture, which was
immediately undone and the selected original was verified. A physical
shortcut check is pending. Captured-text replacement, changed-target
rejection and live Undo are not accepted yet; no external text was sent or
replaced in this update.

---

# Rewrite preview 0.4.0 — September 27, 2026

Signed package: `build/cafe.nero.plugin.voice-0.4.0-51e20d0e3282.app`.
The independent Voice module adds a Rewrite view: exact selected-text capture,
review before optional assistant submission, editable proposal, exact-target
replacement and copied-text fallback. NeroNook 0.26.1 installed the signed
0.4.0 package through its normal update flow. Settings and both display
placements were retained; the module is Running. The installed executable
matches the candidate hash and the deep/strict signature verifies.

Verified: all 25 Swift tests pass, including prompt boundaries/escaping and
the existing exact replacement/undo checks. Release packaging and strict
signature/update verification passed. The signed-process protocol check
passed handshake, SDK validation, three snapshots and clean EOF with no
assistant call. The native Rewrite layout was inspected. In the signed app,
synthetic text was copied, imported as the source, edited locally, copied as a
replacement, and imported again to verify the clipboard contents. This path
works without Agent or a selected assistant.

The installed Voice 0.4.0 restored the previously granted Nero Agent Ask ChatGPT
action with the same scope. A synthetic 35-byte TextEdit phrase was copied and
imported. The explicit polish request returned an editable proposal in Voice;
it happened to be identical to the already polished source. No reply was
automatically pasted. The synthetic TextEdit document was moved from its
automatic iCloud save to ignored local `build/`.

The automated TextEdit selection attempt did not prove direct capture: the
system-wide focused accessibility element reported `AXWebArea` or `AXGroup`
even while TextEdit displayed a selected fixture. Voice refused those roles,
leaving its source empty; no text was sent to an assistant or replaced. A
user-facing error now suggests clicking the editor or importing copied text.
A second attempt after installation and raising TextEdit also got the safe
rejection instead of a captured editor. A manual focused-editor test,
changed-target rejection and confirmed Replace/Undo still need acceptance.
The synthetic TextEdit fixtures are retained under ignored `build/`.

---

# Meetings preview 0.3.0 — September 24, 2026

Installed independent signed package `cafe.nero.plugin.voice-0.3.0-d4774275989a.app` through the normal NeroNook module update. Host shows 0.3.0 Running; existing display placement and settings remain. No host code or OmniVoice files changed in this slice.

Verified:
- 17 existing tests and six new meeting tests pass. New coverage includes SDK view revision validation, stereo resampling and converter-tail preservation, separate track rotation and pause/recovery, metadata validation, rejection of late audio, and conservative speaker assignment with persistent corrections.
- Signed release packaging, deep strict signature validation, and the signed-process handshake/SDK validation/three snapshots/clean EOF check pass.
- Real microphone recording, bookmark, pause, resume, stop, saved library entry and playback work in the installed UI. The short check produced approximately 15 seconds of saved audio; no recording remains active.
- Real system-audio capture saved four CAF chunks over approximately 52 seconds. A locally generated test phrase played through the system was present in the waveform and correctly transcribed through the installed UI, with timestamps around 37 and 39 seconds.
- A transcript correction through the installed editor saved separately from the original recognized text. The original text is retained on disk. Test transcript text is synthetic.
- Native Meetings layout and compact host controls were inspected. The public MLX Audio multi-speaker test fixture imported as a clearly labelled demo produced 12 timestamped Apple Speech phrases in the installed UI. This is a fixture, not a recorded meeting.
- The separately packaged native Sortformer worker processed the 30-second public fixture and returned two generic speaker IDs. Model download hashes and packaged helper execution were checked independently; the optional model preparation/diarization flow has not been exercised end to end through the installed UI.

Acceptance caught and fixed an invalid selected-meeting SDK revision: UUID hyphens violated the SDK key format, causing silent snapshot loss and host timeout. Revisions are now normalized and covered by a regression test; a valid fallback snapshot exposes Stop activity if future view validation fails. The replacement package remains connected during the subsequent live checks.

Boundaries: this is post-recording transcription, not live captions or finalized continuous diarization. Long-meeting endurance, five-to-eight-speaker accuracy, overlapping speech quality, echo handling, exact application/helper capture isolation, unplug/sleep behavior and export UI remain separate acceptance work. General Dictate footer controls still appear below Meetings in the host surface. Short live checks and fixture outputs are not an accuracy benchmark.

At the time of this 0.3.0 release, the owner's newer-model direction was documented in [MODELS.md](MODELS.md): Nemotron 3 Diarization, Parakeet v3, Canary and Kokoro. None was installed or selectable in 0.3.0. Voice 0.7.1 adds Parakeet as an optional saved-meeting provider; the other candidates remain unimplemented.

Evidence is local and ignored by Git: `build/meetings-tests.log`, `build/meetings-protocol.log`, `build/meeting-speech-test.log`, `build/packaged-speakers.json` and the clearly labelled test library entries. No meeting audio is committed or sent to an assistant.

---

# Focus correction and owner acceptance 0.2.1 — September 23, 2026

macOS Accessibility is now granted by the owner and the installed plugin reports Text insertion allowed. Focus capture and revalidation now use the system-wide accessibility focused element, matching OmniVoice's approach, instead of first choosing NSWorkspace's frontmost application. The captured field, text and cursor checks remain in place.

The owner directly confirmed: “Insertion and Undo both work.” This accepts the manual Insert draft / Undo check; it does not establish every editor, shortcut timing, speech accuracy or clipboard-format restoration. The automated UI check did not successfully focus TextEdit: its countdown inserted the harmless fixture into the Chrome search field that actually held keyboard focus. No Search/Send was invoked; the fixture was removed and the empty field verified. This is not recorded as automated TextEdit acceptance. The countdown targets the field focused at its end, as described by the UI.

17 tests, signed release packaging and signed-process handshake/SDK validation/three snapshots/clean EOF pass. Package `cafe.nero.plugin.voice-0.2.1-900bab397daa.app` is installed and Running through the normal host review. The previous package remains available for recovery. The owner's original draft was restored after the update without submitting it. The prior Ask ChatGPT action grant was restored with the same scope; Voice settings show Ask ChatGPT available. No assistant call was made.

Remaining: broad browser/Electron editor acceptance, live clipboard-format and intervening-copy checks, controlled human speech/held-key tests, selected-text rewriting, cleanup/styles and recoverable transcript history. Logs are local ignored `build/focus-*.log`; no personal transcript is included in this record.

---

# Dictation insertion 0.2.0 — September 23, 2026

First slice of the reopened Voice experience review: hold/toggle dictation to the captured cursor, nonactivating overlay, unchanged-target checks, temporary clipboard preservation, verified undo and explicit delayed draft insertion. Review/Copy/Ask remain separate; no assistant submission or ambient capture is added.

Validation so far: 17 core tests pass (eight new edit/shortcut tests); synthetic speech through the production capture-conversion/finalization pipeline retains the complete fixture including final words; independent release packaging and strict signing pass, and signed-process handshake/three valid snapshots/clean exit pass. Native host installation shows 0.2.0 Running, enabled on both displays, prior shortcut retained, and compact activity unchanged. The host retains the previous package for recovery. The corrected settings layout is visually checked and open; Accessibility permission is pending user approval. Live insertion, undo, clipboard restoration and focus-change behavior are not yet accepted.

Package: `cafe.nero.plugin.voice-0.2.0-57fa3bbc0962.app`. Logs under ignored build/dictation-*.log. Human speech and browser/Electron compatibility remain separate acceptance gates. Updating the package invalidated the existing SDK assistant grant as designed; it has not been silently restored.

---

# Microphone capture correction — September 23, 2026

Version 0.1.1 installed: `cafe.nero.plugin.voice-0.1.1-a3dc339e46f2.app`.

The owner reported Record starting without words. Live process logs established a 48 kHz input hardware / 96 kHz client format mismatch, followed by "Failed to create tap, config change pending!" The monitor output was 96 kHz and the MacBook microphone was 48 kHz. The earlier engine-start and silent-stop check did **not** prove that microphone buffers arrived; that acceptance claim was insufficient.

Changed the tap/converter format source from the input node's output/client format to its hardware input format. Listening now waits for actual buffers (three-second startup deadline); a stalled feed also stops after three seconds. The status line identifies the microphone and current input level. Capture statistics store only count/time/level, never audio or transcript content. Interleaved and planar float samples are supported by the meter.

Verified on the installed signed 0.1.1 app: real microphone buffers arrive, live words appear, input level updated (44% observed), and Stop returns an editable finalized transcript. No transcript text is copied into this record or sent to an assistant. New process logs no longer show the hardware/client mismatch or failed-tap message. The 48 kHz reference-audio regression through the production conversion/finalization path recognizes its complete synthetic phrase, including its last words. Nine existing core tests and the signed-process handshake/snapshot/EOF check pass. SDK Ask permission was re-enabled for the new package.

A controlled human phrase/accuracy benchmark, all microphone devices, unplug/sleep and long-held shortcut acceptance remain separate follow-ups. The observed live words establish real microphone-to-recognizer delivery, beyond the earlier silence-only check.

Reference: Apple's [AVAudioInputNode documentation](https://developer.apple.com/documentation/avfaudio/avaudioinputnode) identifies the input scope as the hardware format and requires its output scope to match when rendering from a device.

---

# Local acceptance — September 23, 2026

Independent Nero Voice 0.1.0, macOS 27, Xcode SDK 27, NeroNook host 0.17.0. Final local package: `cafe.nero.plugin.voice-0.1.0-1548f6b48189.app`.

Verified:
- Nine core tests pass: cancelled preparation, stale callbacks, final words, partial preservation, editable/original text, blank/UTF-8 limits, volatile/final assembly, literal dictionary replacement, provider compatibility and submitted-value validation.
- Signed independent release build, SDK manifest/message validation, ordered handshake and three timed snapshots, clean exit after connection closure. Protocol fixture never records audio or invokes an assistant.
- Real Apple Speech file recognition and simulated microphone-buffer conversion/queue/finalization both return “Nero voice keeps my speech on this Mac. These are the last words.” Synthetic audio was generated locally. This verifies recognition and final words for that fixture, not a human speech benchmark.
- Installed through the normal host review, running through application transport with its own bundle identity. Voice's settings/provider selection survive plugin updates. SDK access is invalidated by a new package and explicitly re-enabled for the new build.
- Odyssey Ark's real 16:9 module shows the transcript form, separate status and selector. Standalone transcript changes update the Nook. Reviewed Copy in the Nook produced the exact expected clipboard text.
- A reviewed text request from the standalone Voice UI completed through the existing Nero Agent account route with “Nero Voice is connected.” Spoken-reply UI entered Reading reply aloud/Stop speaking and returned to ready. Output audibility has not been confirmed by the owner. No ChatGPT conversational audio endpoint was used.
- Control–Option–V registers. After the event-identity correction, ordinary Command–A editing and the host's Command–Shift–N shortcut work without starting a recording. Physical held-key dictation remains to verify with the owner.
- The final installed build started the selected physical microphone, remained Listening through a short local check, then Stop finalized and returned No speech detected. No audio was saved or sent. This verifies microphone startup/stop and silence handling; a known spoken human phrase is still pending.

Corrections found during acceptance:
- This OS's asset status query reported supported while the installation-request API returned nil (nothing to install). Use the latter and preserve explicit consent for downloads.
- Filter Carbon events by the registered signature/ID, leaving unrelated shortcut events unhandled.
- An initial audio-configuration notification was mistaken for unplugging. Ignore notifications while the selected device, format and running engine remain healthy; stop on actual route change/failure.
- Keep queued audio bounded, flush the converter tail, drain the final transcript, and reject late results after cancellation. Asset preparation has its own generation token.

Remaining:
- Owner's known-phrase microphone test, first/last word quality, held push-to-talk timing and multi-microphone/unplug/sleep behavior on real hardware.
- Human listening quality, other languages, noisy/long dictation and model comparisons; clean-machine and smaller-display acceptance.
- Automatic target insertion, richer cleanup, MLX recognition and conversational ChatGPT Voice are later work. Public licensing, notarization and distribution are not claimed.

Logs (local, ignored by Git): `test.log`, `package.log`, `speech-fixture.log`, `speech-capture-fixture.log`. Test audio is synthetic; no personal recording is retained. OmniVoice's existing metadata changes remain untouched.


## September 28 — separate interpreter development preview

The signed workspace-bound InterpreterPreview executable is built outside the
installed plugin. Nemotron → Hy-MT2 → Kokoro MLX produces EN↔ES audio locally.
Four fixture runs, both native direction results, playback start and ASR cancellation
passed; cancelled receipt preserved and no worker survived Stop. Five boundary
tests pass. [Evidence, pins and limits](../Workers/Interpreter/README.md).
No installed Voice/host update, virtual driver, Teams call or microphone-capture
acceptance is implied. The preview retains local inputs/results for inspection.


## September 30 — virtual audio driver preparation

Signed local `NeroInterpreterAudio.driver` and `NeroBridgeCheck` built with pinned
MIT-licensed libASPL. In-process checks exercise real device objects and callbacks;
ring checks cover exact transport, isolated routes, timeout/Stop/restart, timestamp
wrap, finite audio and concurrent access. Installer payload and stable driver
signature inspected. Native preview correctly displays Driver not loaded, with
Install/Refresh and a disabled live check. The installer is open for administrator
approval. No driver installation, HAL loading, live transport, physical capture or
Teams result is claimed. [Details](../Drivers/NeroInterpreterAudio/README.md).


## September 30 — installation report correction

Installer log and package receipt confirm the first driver installation succeeded
at 10:55 PDT. A second attempt at 15:24 PDT failed with script error 112 because
the first-install guard found that existing driver. Its code signature verifies
and its executable SHA-256 matches the built package. Core Audio has been running
since September 15 and still enumerates neither Nero endpoint; it has not been
restarted since installation. No audio service restart was performed.

Corrected native setup to distinguish driver presence from device enumeration:
installed-but-not-loaded hides Install and asks for restart/Refresh, rather than
sending the owner through the package again. Invalid helper output now reports a
status error. Live transport remains pending after loading.
