# Source provenance

OmniVoice workspace: `/Volumes/Main External/Development/OmniVoice`, commit d3b5940. Reuse authorized by the owner in the NeroNook voice discussion. The original workspace is unchanged.

- `Sources/ModuleCore/AppleSpeechTranscriptAssembler.swift` from `Sources/OmniVoiceCore/AppleSpeechTranscriptAssembler.swift` (SHA-256 `bab8402f9ce2e8b00f510e06b0c8534c99d5ffa1889c7aef1e25e3ea6d4d3dac`).
- `Sources/VoiceAudio/MicrophoneDeviceService.swift` from `Sources/OmniVoiceApp/MicrophoneDeviceService.swift` (SHA-256 `8c5d02b18307146d12bcf07cd5b765a5e23f65a5e294c6002ff3ec7c81c4bf7a`).

SpeechPipeline and VoiceSession adapt the capture/volatile-final transcript/lifecycle design with rewritten bounded audio and cancellation ownership. Keyboard handling uses public Carbon hotkey registration. No OmniVoice account, license gate, server, model, credential, agent CLI or app binary is bundled. SDK source provenance is in SDK-SNAPSHOT.json. Public licensing/distribution remains a separate decision.
