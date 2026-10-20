October 13 persistent meeting chat and cross-document retrieval are
independently authored Swift/HTML/CSS/JS. The optional shared conversation
contract is deliberately vendored with hashes. Native tests use owned synthetic
text/audio archives; no live capture, vendor assets, credentials or third-party
meeting content are imported. ASR/TTS runtime/model provenance is unchanged.

October 13 calendar linking is independently authored Swift / HTML / CSS / JS.
The shared SDK calendar convention is vendored from NeroNook with its SHA-256
record; EventKit and Google API identities follow their documented behavior.
The native test provider and meeting archive contain only owned synthetic
fixtures, no real meeting capture. No Wispr assets or private APIs are used.

## October 17 · Qwen Voice Studio / local cloning

Voice 0.21.0 adds independently authored native Studio views, bounded selected-
microphone reference recording, normalized private reference storage, archive/
restore and generation-option validation. No new host feature or SDK protocol
is required. Runtime source remains pinned at the revision below.

Optional additional Apache-2.0 models are
[Base 8-bit](https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit)
revision `e7dd0585652209fa0d7783659aad4e8a324de11c` and
[VoiceDesign 8-bit](https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit)
revision `f90d617701d9f7f4ca499291e0b57f2b3c2fd2ee`. Each twelve-file recipe
records size and SHA-256; downloaded non-LFS files were also verified against
the pinned Hub Git blob IDs, and LFS weights against published SHA-256 values.
The original Qwen license already bundled covers these variants. Model files
remain external to the app. Cloning tests use our previously generated Serena
sample, not a person’s recording; there is no audio upload or remote code.

## October 17 · optional Qwen speech

Voice 0.20.0 uses the existing pinned MIT MLX Audio Swift runtime at
`01dec7c9bdce3088a6b6b7ab9f2e403458195efb`, adding its Qwen3TTS model in a
separate `--tts` role of the existing helper. The framed transport, parser,
asset verifier, cancellable renderer and UI are independently authored. Vendor
diagnostics remain off the protocol channel. No Qwen Python or remote model
code is bundled or evaluated.

Optional assets are from
[mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit](https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit),
revision `41d3337e8b7f2843a75841595fc14e4b9a7a4b96`. All twelve files have
pinned size/SHA-256 metadata in `Resources/Models/qwen-tts.json`. The original
Qwen Apache 2.0 license is retained in `Resources/Licenses/qwen-tts.txt`.
Previously auditioned local weights were verified and reused outside the app;
downloads on other machines require explicit preparation. Native tests contain
only authored text and generated audio, not real recordings or cloned voices.
[Delivery and limits](reports/qwen-tts-2026-10-17/README.md).

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

## 0.7.1 optional meeting ASR

The same pinned MLX Audio Swift source builds a separate `NeroParakeet` executable inside Voice. It reads saved 16 kHz mono meeting tracks only after a direct Transcribe action. The optional model is NVIDIA Parakeet TDT 0.6B v3, converted and encoder-INT8 quantized by beshkenadze, revision b58cb0ec089186177382a49ffd2109ae1a7664b5. Its three required files have pinned sizes and SHA-256 values in `MeetingParakeetEngine.swift`; the package contains attribution and a license link, while weights are downloaded only by Prepare Parakeet. Apple Speech and Parakeet write distinct transcript files so reviewed corrections survive comparison. No Python, hosted transcription, microphone access by this worker or model code download is involved.

## Voice 0.8 Nemotron

Native Nemotron ASR uses the existing pinned MIT MLX Audio Swift source. The
Nemotron 3 diarization worker vendors the minimal unchanged MIT MLX Audio source
subset at 94c7716212b2228f178d2f9c7619a591fd1b0b78 with its LICENSE. CPython,
NumPy and MLX retain their distribution metadata/licenses in the bundled runtime.
Weights download independently under NVIDIA Open Model / OpenMDW-1.1 terms;
see Resources/Licenses/nemotron-models.txt. Original Nook dictation card authored
locally; no extracted product assets.

The native upstream NemoAlignment segment serializer has a source-hash-guarded
local patch in scripts/patch-mlx-audio.py to expose existing word timing. Model
weights, token decoding and inference are unchanged. This patch is reapplied
by the packaging script and supports speaker-turn grouping without guessing
word timing.


### Local interpreter development preview

`Sources/InterpreterPreview` and `Workers/Interpreter` are independently authored.
The prototype uses pinned MLX Audio, MLX LM, Misaki, Hy-MT2 and Kokoro packages/weights;
[versions, retained receipts and upstream links](Workers/Interpreter/README.md).
Ora and LiveTranslate informed the cascade/virtual audio architecture; no source
was copied. These development dependencies are not part of the installed package;
model/runtime redistribution licensing remains a release gate.


### Optional interpreter virtual audio driver

`Vendor/libASPL` contains the include/src/code-generation subset of gavv/libASPL
commit 633e0f70203edd87d320fc5a3cae901e1363aac5 (MIT, with bundled Apple notices).
All three license files are retained in the source and driver resources. Generated
accessors derive from those vendored sources. The Nero route/ring, lease protocol,
bridge checker and installer code are independently authored; the driver factory
uses the documented libASPL construction pattern. No BlackHole source is included.

## Voice 0.10 · shared Apple speech / Ember renderer

The owner authorized Fuego reuse. `Resources/Speech/apple_voice.swift` is an
exact copy of Fuego's `native/desktop/Sources/FuegoDesktop/Resources/Speech/apple_voice.swift`
(SHA-256 `9b50862bc31b86cfa53182e479f48334808855c7362ff8c2e32c7f7015a9d18e`).
`Sources/VoiceAudio/LocalSpeechProcess.swift` is an exact copy of Fuego's
`native/desktop/Sources/DesktopCore/LocalVoiceProcess.swift` (SHA-256
`69b79d1b0399c53710d5d2d35cdeefcdcb592fb7de809e35a5482396a324ea30`).
Voice's new wrapper validates the render receipt and PCM file and owns local
playback/cancellation. No Fuego credentials, conversation history, compute
client or cloud code is imported. Apple voice content remains macOS-owned.
Notebook storage, evidence formatting and summary/UI code are independently
authored. Wispr's documented behavior guides requirements; no vendor code or
assets are copied. Public licensing remains a separate product decision.

## October 13 · live meeting delivery

MeetingLiveState, MeetingLiveAudioFeed, MeetingLiveTranscriber and the meeting
controller/view extensions are independently authored. The existing owner-
authorized OmniVoice AudioBridge gains optional sample-exact timestamps; its
untimestamped dictation path remains available. The existing MIT-licensed
mlx-audio-swift 01dec7c9bdce3088a6b6b7ab9f2e403458195efb runtime remains pinned.
The independently authored NeroASR worker adds a bounded two-track framed-input
mode sharing one model; upstream source/weights/licensing are unchanged. A
dedicated developer demo identity feeds bundled synthetic audio only and does
not register the dictation shortcut. Normal installed packages have no demo
metadata. No NotchNook code/assets or account tokens are used.

## October 13 · cited meeting questions

The original transcript-only snapshot/retrieval, source navigation and question
view are independently authored here. The optional evidence-answer adapter is
a shared NeroNook SDK source vendored byte-for-byte into Voice and Agent, with
its digest in SDK-SNAPSHOT.json. No new external model, third-party assets or
OmniVoice account material is imported. Synthetic source text and existing
owned test audio are used for acceptance; notebooks/audio are excluded from
provider requests. See docs/ASK-MEETING.md and the versioned delivery report.

## Local meeting library/import · 13 October 2026

MeetingOrganization, import provenance, MeetingLibrary and MeetingRecordingImport
are independently authored. Decoding uses Apple's AVFoundation AVAssetReaderAudioMixOutput
and CoreMedia sample buffers; no third-party import app, executable or assets are
required. Sources: https://developer.apple.com/documentation/avfoundation/avassetreaderaudiomixoutput
and https://developer.apple.com/documentation/coremedia/cmsamplebuffer.
Test WAV derives from the existing independently generated synthetic CAF retained
in the calendar-links report. Test video is a locally generated flat-color H.264
track with synthetic AAC audio, not a recording of a person or screen.

## Dictation personalization · 13 October 2026

Independently authored app-style rules, explicit snippet expansion/marker guards,
local history/retention and module-owned HTML views. Existing PushToTalk and paste
components retain their OmniVoice provenance and were not replaced. Native window
lifecycle uses the vendored generic SDK PluginWindows; no host implementation or
model/account credential import. QA uses synthetic typed text and an explicit
Core-store history fixture, not a captured user microphone or focused field.

## Teams offers and source speakers · 15 October 2026

Independently authored call debounce/lifecycle, public Core Audio process ownership
metadata, bounded AX call-button observer, nonactivating native offer, timed-text
adapter, speaker state/feed and streaming worker protocol. No Teams browser session,
participant names or call contents are read for detection. No capture starts during
observation. Source engine implementation remains the existing vendored mlx-audio
snapshot with its retained license; model revision/license are unchanged. Authored
QA voices were generated locally with Apple's installed Samantha and Daniel voices;
the same file feeds two separate synthetic source clocks, not physical devices or
a Teams call. Existing microphone/paste components retain OmniVoice provenance.

The MLX timing handoff carries existing alignment through the bounded helper
protocol. Independently authored whitespace reconciliation preserves every
recognized character and timestamp; it rejects content differences. This fixes
whitespace-only tokenizer tokens preventing exact-text turn splitting. No model
weights or decoding algorithm were modified.
