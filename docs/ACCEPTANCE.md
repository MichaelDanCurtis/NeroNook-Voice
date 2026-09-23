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
