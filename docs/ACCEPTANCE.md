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
