## October 17 · Voice 0.21.0 Qwen Voice Studio

Separate native configuration now offers the existing CustomVoice presets,
optional Base voice cloning and optional VoiceDesign descriptions. Each is
approximately 3.1 GB of pinned downloadable MLX weights; only one Qwen model is
resident at once. Saved cloned voices store reference audio/transcripts rather
than model copies. The warm worker caches one selected reference encoding.
Generation controls are validated and persisted; unsupported style controls are
hidden for the Base cloning path. [Usage and limits](QWEN-SPEECH.md).

## October 17 · Voice 0.20.0 optional Qwen TTS

Apple remains the new-setup default. Optional Qwen3-TTS 12Hz 1.7B CustomVoice
8-bit MLX is selectable on the primary card and in settings, with nine presets
and the existing delivery styles. The 3.08 GB assets are pinned and verified
separately from the app. Prepare loads without capture; Release and 60-second
idle expiry unload the model. Streaming output shares Agent/Fuego's existing
speech provider and Talk's echo reference. It adds MLX/GPU and memory load;
it does not claim Neural Engine use or Apple's resource footprint. Existing
ASR choices, including one recognizer at a time, are retained. Qwen TTS is a
separate model when used alongside ASR for Talk.

[Usage, model revision and qualification](QWEN-SPEECH.md).
The historical Apple-only output notes below describe earlier versions.

## October 16 · Voice 0.19.2 local latency follow-up

Voice 2 still uses the exact installed Apple voice through the fixed Swift
interpreter: a compiled probe could not access that voice and was rejected.
A bounded stdin/stdout session now amortizes interpretation across chunks. It
starts only for explicit playback/Talk preparation, never opens a microphone or
synthesizes until text is supplied, denies network access, has one render in
flight and closes after 30 idle seconds or at Talk shutdown. Cancellation retires
the complete process group; a later playback opens a fresh session. After long
user turns, renderer preparation overlaps the Agent request.

This costs resident process memory while ready: one local observation was about
247 MiB RSS, including mapped/shared frameworks; neither unique memory nor peak
energy was measured. It does not establish a fan/no-GPU claim. The exact voice's
Apple developer-tools requirement remains. Public release is still held.

## October 15 · one speaker model, two independent sources

Voice 0.18 retains the pinned Nemotron 3 model/revision. A single MLX worker
owns independent room/call state and provisional source-scoped IDs. Live context
uses chunk_len 32 and right_context 8 (2.56 s / 0.64 s); the existing longer-context
file pass is unchanged. Apple Speech supplies actual word timing; punctuation is
attached without inventing alignment. A selected MLX recognizer exits before
speaker analysis starts. Turning Separate room & call speakers off skips automatic
analysis; explicit Identify speakers can still run. Live queue/model failure leaves
durable audio intact. [Acceptance and limits](TEAMS-AND-SPEAKERS.md).

## October 13 · Apple Voice 2 and local notebook drafts

Voice 0.10.1 adds the Ember-compatible Apple American English Voice 2 renderer.
The compiled app's regular AVSpeech catalog still does not expose that Siri
voice directly. Voice invokes a bundled fixed Swift script through Apple's
`/usr/bin/swift`, denies network access, sends bounded text through stdin and
validates a private mono WAV before native playback. Requires the installed
Simone voice and Apple Swift developer tools on this Mac. A clean-machine
redistribution strategy remains open. Other native Apple voices do not use the
helper. No missing-voice request silently switches to another provider.

Meeting summary drafts use Apple's on-device FoundationModels when Apple
Intelligence is enabled. Source-ID output and deterministic clocks address an
observed invented-date failure; general factuality and long-meeting retention
remain review gates. [Notebook limits](NOTETAKER.md).

# Selectable local audio models — Voice 0.9

## Speech output

The owner chose Apple synthesis after auditioning identical passages against
Kokoro and Qwen. Voice 0.9 adds voice selection, Natural / Warm & soft / Lower &
relaxed delivery, Preview, Read draft and immediate Stop. It loads no MLX TTS
model. Explicit saved voice choices remain saved; an unavailable voice produces
an error rather than silently switching. Automatic selects a voice from the
current app's catalog for its selected language.

The catalog is the public `AVSpeechSynthesisVoice` inventory available to the
signed app. The comparison's Swift-interpreter catalog can differ from a native
app's inventory, especially for Siri Voice 2. Audition availability is not an
installed-product claim. Playback has a 2 KB text limit and 180-second deadline;
Stop, replacement, sleep and shutdown retire late callbacks. Dictation/meeting
capture and speech playback are mutually exclusive. Neural TTS and generic
cross-plugin speech remain later work. Existing ASR model downloads and selected
providers are preserved.

## Speech recognition and speakers

Checked upstream model cards and runtime sources on September 28, 2026. **Apple
Speech remains the default for dictation and meetings.** The main Dictate card
and native Voice window now expose the model selector directly. Meetings has its
own selection and separate saved transcripts. Selecting a model never starts a
download or switches a recording already in progress.

| Provider | Local implementation | Use |
| --- | --- | --- |
| Apple Speech | System-managed, on-device | Default; live dictation and saved meetings |
| Nemotron 3.5 ASR Streaming 0.6B | MLX community 8-bit; 756 MB | Streaming dictation with partial words; saved meetings |
| Parakeet TDT 0.6B v3 | Existing MLX encoder INT8; 755 MB | Dictation after release; saved meetings |
| Nemotron 3 Diarization | MLX community BF16; 199 MB | After meeting transcription; up to eight generic speakers per track |

There is one shared native speech worker. It loads **only the selected ASR** and
exits before speaker analysis or text polishing. A process lease also prevents a
new model from starting while a cancelled worker is still exiting. The speaker
worker carries state across all chunks and flushes final lookahead. Speaker
numbers are estimates, not identity recognition; overlaps remain unassigned when
an utterance cannot confidently be attributed to one speaker. Existing reviewed
labels are preserved. Apple, Parakeet and Nemotron have separate transcript files.

Nemotron dictation uses MLX Audio Swift's incremental stream session with 560 ms
model chunks. This is model buffering, **not measured end-to-end latency**. The
microphone starts only after its selected recognizer is ready. Audio goes through
a bounded memory buffer and pipe, not a network service. Apple streaming remains
unchanged. Parakeet's bounded dictation audio is temporarily written to a private
folder for file inference and removed afterward or on cancellation. Unclean
process termination can leave temporary artifacts for OS cleanup; it is not a
persistent dictation history feature.

## Pinned versions

- [Nemotron 3.5 MLX 8-bit](https://huggingface.co/mlx-community/nemotron-3.5-asr-streaming-0.6b-8bit):
  `7279359e4481b5e9e185a318bd618e429c6d86cd`; model SHA-256
  `a64a4da048e7d28dde4cd4ff61ce59308a63314bb5563e73e06c24aae50ea941`.
- [Nemotron 3 Diarization MLX](https://huggingface.co/mlx-community/Nemotron-3-Diarization):
  `59ed2dbfc1346dcea9d423c71306a3a2499c568f`; model SHA-256
  `21e8427d1795c9c46c5800f56b16061734ffd0dcadd71d9bcf0b4d6ef7261da5`.
- [Parakeet MLX encoder INT8](https://huggingface.co/beshkenadze/parakeet-tdt-0.6b-v3-mlx-encoder-int8):
  retained `b58cb0ec089186177382a49ffd2109ae1a7664b5`; model SHA-256
  `72545483758dd40c038acc9afbc9e466ee5bb9819cb93efcc07dbe9015893d2b`.
- [MLX Audio Swift](https://github.com/Blaizzy/mlx-audio-swift):
  `01dec7c9bdce3088a6b6b7ab9f2e403458195efb` (current upstream main when checked).
- [MLX Audio](https://github.com/Blaizzy/mlx-audio):
  `94c7716212b2228f178d2f9c7619a591fd1b0b78`, vendored MIT speaker implementation;
  private CPython 3.12.11, MLX/MLX Metal 0.31.1, NumPy 2.4.3 runtime.

The native runtime has one reviewed local metadata patch (`scripts/patch-mlx-audio.py`):
expose already-computed word timing in segment results. Decoding and weights are
unchanged. This allows speaker changes to split unreviewed paragraphs at actual
word boundaries. Missing word timing is never invented, and corrected/reviewed
utterances are not split. `runtimeRevision` records the upstream commit; the
installed app version and this patch are part of the complete runtime provenance.

The Swift runtime does not yet implement Nemotron 3 diarization. Voice therefore
bundles an isolated, signed Python/MLX runtime in its resources and expands it
into Voice-owned storage on Prepare speakers. The user installs no Python and
runs no server. The compressed runtime has a package-specific verified SHA-256;
all model files have pinned sizes and hashes checked before inference. There is
no runtime pip install, dynamic model-code download or cloud fallback. See
[worker build details](../Workers/NemotronSpeakers/README.md) and bundled licenses.

Canary translation, other streaming families and Kokoro TTS remain future work.
This release does not add a model catalog or keep multiple models resident.

## Evidence and remaining acceptance

Synthetic speech has passed through the native Nemotron file and incremental
workers, including partial updates and final flush. Nemotron speaker inference
has processed the same fixture. Tests cover provider separation, speaker-eight
bounds, preserving reviewed labels, microphone-buffer overflow and shortcut
validation. See [acceptance](ACCEPTANCE.md) for installed-app checks.

These are integration checks, not a comparative accuracy benchmark. Real accents,
technical vocabulary, overlapping meetings, five-to-eight speakers, four-hour
recordings, battery/thermal behavior and repeated physical hold/speak/release
still need acceptance. No best-WER, fanless operation or diarization parity claim
is made. Default model choice remains Apple Speech as requested.
