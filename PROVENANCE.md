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
