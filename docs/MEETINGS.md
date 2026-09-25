# Nero Voice: dictation and meetings

September 24, 2026. Product discussion and source assessment, following the owner's request for meeting recording and diarization. This extends Voice's planned scope; it does not replace the ongoing continuous-Agent work or claim an installed meeting feature.

## Product shape

Keep two main experiences: **Dictate** and **Meetings**. Dictate retains its immediate shortcut, cleanup, correction, rewrite, insertion and undo workflow. Meetings opens a recording session or the searchable meeting library. Recording controls and a live transcript fit the 16:9 module; the full window provides playback, editing, speakers, notes and history. Setup remains behind the gear.

Voice owns capture, local transcription, speaker separation, recording storage and transcript editing. Agent optionally reasons over an explicitly shared meeting or excerpt. Neither product depends on the other being installed. A summary, suggested action item or someone saying an imperative during a call cannot itself execute a Mac/module action.

## What the first meeting feature should include

| During a meeting | After a meeting |
| --- | --- |
| Explicit Record, Pause, Resume and Stop; visible elapsed time and source meters | Playable saved audio with transcript timestamps that seek to the corresponding moment |
| Microphone for a room conversation; chosen call-app audio plus microphone for online meetings | Speaker rename, merge and correction, without altering the original audio |
| Live provisional words and speaker turns, with clear recording/transcribing status | A final transcription/diarization pass that can refine provisional labels while preserving user edits |
| A bookmark button and optional manual notes | Search, title/date, local export to Markdown, JSON and timestamped captions |
| An explicit entry to Ask about a selected excerpt | Optional Agent summary, decisions and proposed action items linked to transcript evidence |

Use recording-specific durable storage rather than extending today's short dictation buffer. Stream bounded audio chunks to disk, keep microphone and remote audio as separate tracks on a common clock, and journal finalized transcript segments. Disk-full, device loss, permission loss or app failure must surface a recoverable partial session. Do not hold an entire long meeting in RAM or wait until Stop to save it. Playback and raw-audio retention need clear storage/delete controls.

Preserve recognized text alongside user edits. Dictation-style cleanup or an AI rewrite must not silently become a verbatim meeting quotation; summaries and suggested wording remain separate from the source transcript.

Source scope is visible: the chosen meeting app where supported, or an explicitly labelled whole-system source. A process tap must track the chosen app's actual audio processes, including helpers, and explain when that scope cannot be isolated. Record/Stop comes from the user; a calendar can offer a recording shortcut rather than silently starting capture. Microphone/system audio recording and Agent screen observation remain independently controllable.

## Speaker separation

Diarization answers **which speaker spoke when**. It does not establish a person's name. Start with neutral speaker labels and let the user name or correct them. Any future cross-meeting voice recognition needs its own opt-in identity feature.

Keep capture tracks separate, but do not equate a microphone with exactly one person. A room microphone may capture several people or speaker playback; remote audio may contain several participants. Track provenance helps alignment and echo handling, while diarization separates voices within a track. Preserve overlap/uncertainty instead of inventing a precise speaker assignment. Online headset, laptop-speaker echo and in-person room setups need different tests.

Sortformer through MLX is the first candidate because the owner's OmniVoice already integrates it. The current selected checkpoint is the four-speaker `diar_streaming_sortformer_4spk-v2.1` family. Do not advertise arbitrary-size meeting support from that model. Evaluate an alternate local pipeline for larger groups, such as pyannote Community-1, or explicitly label unsupported/uncertain cases. Its model access conditions and deployment cost require separate review; no new model has been downloaded or terms accepted here.

Live speaker IDs need session-wide continuity across chunks. A post-meeting pass may improve alignment and segmentation, but must not overwrite manual names or edits. Benchmark speaker error and word/speaker alignment, not just whether a provider returns a valid array. Use both small conversations and recordings beyond four speakers.

## OmniVoice code worth adapting

Source reviewed at `d3b5940307a443bc2e57ae99f000e019cb5558ea`. The owner authorizes reuse of their code. Preserve attribution and relevant tests while extracting independently bundled components; never depend on the OmniVoice installation or its fixed engine port.

- `Sources/OmniVoiceApp/ConversationRecorderService.swift`: streaming segment lifecycle, finalization, generation-bound updates and diarization previews.
- `Sources/OmniVoiceApp/SystemAudioCaptureService.swift`: Core Audio process-tap lifecycle. The current implementation captures all system output; narrow the source before adopting it as a selected-app recorder.
- `Sources/OmniVoiceCore/ConversationModels.swift`, `ConversationDiarizedTranscript.swift`, timing/ordering/accumulator helpers: transcript structure, timestamps, speaker display and corrections.
- `Sources/OmniVoiceCore/ConversationArchive.swift`: Markdown/JSON library export. This archive does not save complete playable audio; the current system tap's `stopWAVData()` returns empty data. A durable audio recorder is new work.
- `Sources/OmniVoiceCore/TwoTrackConversation.swift`: stable microphone/remote track identities, currently labelled Me/Them. This is track attribution, not multi-person diarization. Do not copy its assumption that a mic can only be the user.
- `engine/omnivoice_engine/diarization.py` and `conversation_alignment.py`: local Sortformer adaptation and transcript alignment. The adapter calls inference over supplied audio windows; measure stable identity across window boundaries rather than assuming continuity from the model's name. Its threshold-lowering fallback tries to recover multiple speakers; validate false splits rather than assuming more labels means higher accuracy.
- Conversation, diarization and alignment tests: useful extraction checks, but many model tests use fake outputs and do not establish real speaker accuracy.

Native MLX Audio Swift now documents Sortformer support. Compare that independently bundled path with OmniVoice's Python provider before choosing packaging. Preserve the effective local provider abstraction; a supported model in a README is not an integrated or benchmarked Nero feature.

## Agent connection

Use the generic SDK for explicit meeting/excerpt selection, permission-filtered transcript reads and bounded events. Voice retains the source recording and stable timestamp/segment identifiers. Summaries and action proposals cite those identifiers and indicate uncertain speakers. Sensitive or local-only meetings never become automatic Agent context. No duplicated ChatGPT authentication or cloud-audio fallback enters Voice.

Later ideas: calendar-linked titles, topic chapters, searchable cross-meeting decisions, a private question panel during a call, and reviewed follow-up tasks. These are later additions, not reasons to delay reliable recording and playback.

## Delivery and evidence

Preserve the current Agent work's priority. For Voice, finish the useful dictation improvements while defining a separate meeting session lifecycle. Then deliver:

1. Reliable long-session recording, separate tracks, journal/recovery and playback.
2. Live/final local transcripts and measured speaker separation, with editable identities.
3. Meeting library, search/export and optional evidence-linked Agent summaries/tasks.

Acceptance includes 60–120-minute recordings, stop/finalization, pause without gaps being misrepresented, crash recovery, disk limits, source isolation, output-device changes, echo/overlap, more than four speakers, stable names across chunks, offline processing and review before sharing meeting context. This turn only inspected source and updated scope; no meeting capture, inference benchmark, application build or live test was performed.

## Primary references

- [Apple Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps) and [ScreenCaptureKit audio capture](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos).
- [MLX Audio diarization models](https://github.com/Blaizzy/mlx-audio/blob/main/docs/models/vad/index.md) and [MLX Audio Swift](https://github.com/Blaizzy/mlx-audio-swift).
- [NVIDIA Sortformer documentation](https://github.com/NVIDIA-NeMo/Speech/blob/main/examples/speaker_tasks/diarization/README.md).
- [pyannote Community-1](https://huggingface.co/pyannote/speaker-diarization-community-1), an alternative local evaluation candidate with gated model access.
