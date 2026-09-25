# Source provenance

OmniVoice workspace: `/Volumes/Main External/Development/OmniVoice`, commit d3b5940. Reuse authorized by the owner in the NeroNook voice discussion. The original workspace is unchanged.

- `Sources/ModuleCore/AppleSpeechTranscriptAssembler.swift` from `Sources/OmniVoiceCore/AppleSpeechTranscriptAssembler.swift` (SHA-256 `bab8402f9ce2e8b00f510e06b0c8534c99d5ffa1889c7aef1e25e3ea6d4d3dac`).
- `Sources/VoiceAudio/MicrophoneDeviceService.swift` from `Sources/OmniVoiceApp/MicrophoneDeviceService.swift` (SHA-256 `8c5d02b18307146d12bcf07cd5b765a5e23f65a5e294c6002ff3ec7c81c4bf7a`).

SpeechPipeline and VoiceSession adapt the capture/volatile-final transcript/lifecycle design with rewritten bounded audio and cancellation ownership. Keyboard handling uses public Carbon hotkey registration. No OmniVoice account, license gate, server, model, credential, agent CLI or app binary is bundled. SDK source provenance is in SDK-SNAPSHOT.json. Public licensing/distribution remains a separate decision.

## 0.2.0 dictation insertion

Reviewed OmniVoice's `TextInsertionService.swift`, `TextInsertionEdit.swift` and `TextInsertionTargetPolicy.swift` at the same d3b5940 revision. DictationEdit adapts its UTF-16 replacement planning, with explicit surrogate-boundary and stale-selection checks. DictationInsertion adapts captured-target and transient-clipboard ideas; it deliberately does not carry over current-focus fallback, whole-field replacement, synthetic Unicode typing or unconditional undo. All code ships inside the independent Voice package; OmniVoice remains untouched.

The floating overlay uses Apple's [nonactivating panel behavior](https://developer.apple.com/documentation/appkit/nspanel/becomeskeyonlyifneeded). Permission setup uses [AXIsProcessTrustedWithOptions](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions); permission is requested by the explicit settings button, never at launch.

## 0.2.1 focus lookup

Adapted OmniVoice's system-wide Accessibility focused-element lookup from the same reviewed d3b5940 source. Capture derives the owning process from that element, and revalidation requires the identical focused element. No fallback paste target or automatic Send is added.

## 0.3.0 meeting capture and review

`MeetingCapture.swift` adapts the Core Audio process-tap lifecycle from OmniVoice's `SystemAudioCaptureService.swift` at d3b5940307a443bc2e57ae99f000e019cb5558ea. Audio journaling/rotation, common timeline, recovery, playback and the meeting library are new independent code. Meeting transcription uses Apple's native SpeechAnalyzer file API and final result ranges. Original text is retained separately from corrections.

`Workers/Diarization` pins Blaizzy/mlx-audio-swift at 01dec7c9bdce3088a6b6b7ab9f2e403458195efb. It bundles an independently signed native executable and signed MLX Metal library. See its Package.resolved and Resources/Licenses. It uses local Sortformer streaming state and preserves exact sample-clock offsets across inference blocks; the model's output is treated as estimated activity, not identity.

Optional model: mlx-community/diar_streaming_sortformer_4spk-v2.1-fp16 revision e23e6404bd9859e93edbf94a740eb1c7fc58f12e. Configuration SHA-256 17c9f943bed07b0593f2b8dca01e0be6a418053becc6148b01ecabdff9cbd84d; weights SHA-256 3b60b8df29e59a8abaf8061ceeeae6e9284a68fbcd2e762c68f5e058bfceebfa. The NVIDIA model license link is included with the package; weights are downloaded separately. No account token or remote code execution is used in preparation.

The MLX Audio Swift repository's public `Tests/media/multi_speaker.wav` was used as a 30-second local integration fixture. Its test copy is clearly labelled in the local library and is not represented as a user meeting. The microphone/system capture checks and ASR fixtures are separate evidence from diarization accuracy.
