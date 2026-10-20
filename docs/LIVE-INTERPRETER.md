# Live Interpreter — prototype and architecture, September 28, 2026

Status: the local EN↔ES native preview works with Nemotron → Hy-MT2 → Kokoro.
September 30: the optional two-route HAL driver and isolated bridge checker are
built and signed; in-process checks pass. Administrator installation and real HAL
verification are pending. [Driver handoff](../Drivers/NeroInterpreterAudio/README.md).
See [reproduction and measured limits](../Workers/Interpreter/README.md). No virtual
driver installed, Teams routing changed, or meeting audio captured. This is a new Nero Voice capability, reusing the owner's
OmniVoice work where appropriate. OmniVoice need not be separately installed.

## Intended experience

Choose **My language: English**, **Meeting language: Spanish**, physical microphone
and headphones. In Teams choose **Nero Interpreter Microphone** as its input and
**Nero Interpreter Speaker** as its output. Start Interpreter explicitly.

- Incoming: Teams Spanish audio → virtual speaker → speech translation → English
  synthesis → physical headphones. Original audio is not monitored by default.
- Outgoing: physical microphone English → speech translation → Spanish synthesis
  → virtual microphone → Teams. Raw microphone audio is not passed through.
- Main card: language pair, independent listen/speak mute, source/translated
  captions, delayed/ready state and Stop. Original-audio listening is an explicit
  option. Outgoing bypass must be explicit, never a fallback on model failure.
- Two independent queues and stream identities; never feed synthesized playback
  into recognition or mix incoming meeting audio into the outgoing microphone.

## Virtual audio product boundary

Use a separately signed, optional Core Audio AudioServerPlugIn driver with two
named endpoints and an independent Voice-owned bridge service. Apple recommends
this HAL approach for virtual audio; AudioDriverKit is for physical devices.
The driver performs bounded audio transport only, never model inference. Use
48 kHz float PCM transport, explicit resampling to model rates, monotonic frame
counters, bounded ring buffers and drift handling. Callbacks must not block or
allocate. Process death or missing producer yields silence, never stale replay.

The bridge publishes only translated outgoing speech to the Teams input. It reads
Teams output separately and sends translated incoming speech to selected hardware.
Start with headphones; speakerphone echo cancellation is a separate acceptance task.
Host NeroNook owns neither model nor driver implementation. Driver install/update/
uninstall is separate from ordinary plugin updates and may require macOS admin
approval/restart. No audio-server restart during an active meeting. Preserve and
restore routes only when still owned by the session; do not overwrite later user
choices. No global default-device change is required for Teams-specific selection.

BlackHole is a useful loopback reference/prototype option, but its GPL/commercial
licensing must be resolved before incorporating it in a distributed product. Prefer
an independently authored driver using Apple's documented interface and permitted
sample code, with attribution. Do not promise a production driver from a build alone.

## Research shortlist — retained alternatives, not the current delivery plan

The owner asked to use existing evidence and move forward. Build the single
Nemotron → Hy-MT2 → Kokoro path first; revisit alternatives only for a measured
failure. The research table below is historical context.

No winner selected. The first Canary recommendation was too narrow. Check both
translation quality and complete audio-to-translated-audio delay on this Mac.
The MLX Community catalog contains useful alternatives; a supported model name
or streamed output alone does not establish continuous incoming-audio support.

| Candidate | Role and evidence | Decision |
| --- | --- | --- |
| Nemotron 3.5 ASR 0.6B + Hy-MT2 1.8B 4-bit + local TTS | Existing MLX streaming recognizer plus specialized 33-language translator; English and Spanish supported; MLX Community weights available | First streaming cascade to compare; adds translation stage and memory, not a proven speed winner |
| Granite 4.0 1B Speech MLX + local TTS | IBM explicitly supports bidirectional English/Spanish speech translation; MLX Community quantizations and MLX Audio translation API | Deferred direct-speech alternative |
| Canary-1B-v2 MLX + local TTS | NVIDIA bidirectional speech translation; MLX conversions documented under Mediform and qfuxa rather than mlx-community | Retain as baseline; no longer presumed best |
| TranslateGemma 4B MLX | Specialized text translation; already represented in OmniVoice plumbing | Quality comparator if Hy-MT2 misses accuracy requirements; larger model |
| Kokoro-82M MLX / Supertonic 3 MLX | English/Spanish TTS; Supertonic 3 now has community graph-runtime conversion | Compare synthesized clarity and first-audio delay; Supertonic uses a separate runtime, not assumed drop-in |
| Qwen3-ASR 0.6B / Voxtral Realtime 4B MLX | Alternative recognition front ends | Secondary only if existing Nemotron recognition fails the bilingual fixture |
| Hibiki-Zero | Purpose-built simultaneous translation including Spanish→English; official runtime requires NVIDIA GPU, reverse English→Spanish not listed | Good architectural reference, not current bidirectional MLX solution |
| LFM2.5-Audio 1.5B MLX | Compact end-to-end audio; official supported language is English | Does not meet documented Spanish requirements |
| NemotronLabs VoiceChat 11B MLX | Full-duplex conversational speech model; official card describes English conversation, no verified bidirectional Spanish interpreting | Not established as an interpreter; heavier than our intended local path |
| Granite Speech 4.1 2B NAR MLX | Newer recognition conversion explicitly says no streaming inference | A higher version number does not replace the translation candidate without task verification |

MLX Granite streams generated output tokens after preparing the supplied audio;
that is not proof of incremental microphone encoding. Canary's MLX API likewise
exposes phrase/file generation. NeMo's Wait-k/AlignAtt streaming implementation
must not be attributed to MLX without a port and tests. For both direct models,
measure bounded phrase processing with realistic end-of-phrase detection.

A text cascade can consume committed ASR phrases and enforce a terminology list,
but ASR errors propagate and total compute may exceed the direct models. Test
names, numbers, negation, self-corrections, accents and interruptions in both
directions. Use Kokoro for the first working path; defer additional model
comparisons unless this path fails a specific requirement. No claiming a
winner from source documentation or upstream CUDA throughput benchmarks.

The installed Voice app serializes its own MLX workers. The developer preview
serializes ASR, translation and TTS separately; its lock does not span other apps.
Production integration must share Voice’s coordinator. Begin with
serialized work and measure queue growth; resident ASR, translation and synthesis
weights may be necessary for low delay. That changes the one-loaded-model policy
and needs an explicit product choice if measurements demand it. No promise of
fanless operation or fixed latency. Diarization stays outside the critical path.
No voice cloning needed. Inspect model/runtime licenses before distribution.

## Delivery and acceptance

| Stage | Work | Gate |
| --- | --- | --- |
| 1 | Focused EN↔ES native MLX preview — implemented | Four fixture runs and both native directions pass; 2.04–4.54 s warm stage time. Real speech/quality, sustained pacing and thermal behavior remain unverified |
| 2 | Two-route HAL driver, signed installer and native bridge check built | In-process fixed-format, isolation, expiry/Stop and restart pass; administrator installation, real HAL IO and Teams selection pending |
| 3 | Inbound listening translation | Dedicated test call, only English in headphones, original route isolated, bounded delay over 30 minutes |
| 4 | Outbound and two-way operation | Remote endpoint hears only Spanish; mute/Stop flush queued speech; interruptions, overlapping speakers, device loss and sleep handled without replay |
| 5 | Independent packaging and primary card | Signed installation/removal/recovery; Teams and a second app verified; existing dictation/meetings remain usable |

Record delay distributions and sustained queue growth, not just model decode speed.
Target conversational phrase-level delay of a few seconds as a hypothesis to test,
not a measured capability. Never silently summarize or drop backlogged words. Signal
lag; stop or request a pause when the bounded queue fills. Persist neither audio nor
transcripts unless recording is separately enabled. No cloud fallback.

## Sources

- Apple virtual driver guidance: https://developer.apple.com/documentation/CoreAudio/creating-an-audio-server-driver-plug-in
- Apple DriverKit scope: https://developer.apple.com/documentation/audiodriverkit/creating-an-audio-device-driver
- NVIDIA model: https://huggingface.co/nvidia/canary-1b-v2
- NVIDIA streaming: https://docs.nvidia.com/nemo/speech/nightly/asr/streaming_decoding/canary_chunked_and_streaming_decoding.html
- MLX Canary: https://github.com/Blaizzy/mlx-audio/blob/main/mlx_audio/stt/models/canary/README.md
- MLX Kokoro: https://huggingface.co/mlx-community/Kokoro-82M-8bit
- Supported TTS languages: https://github.com/Blaizzy/mlx-audio
- BlackHole: https://github.com/ExistentialAudio/BlackHole

Local grounding: OmniVoice README, translation provider models and EngineClient;
Nero Voice 0.8 model workers, meetings source capture and shared process lease.

Additional sources from the second review:

- https://huggingface.co/mlx-community/Hy-MT2-1.8B-4bit
- https://huggingface.co/tencent/Hy-MT2-1.8B
- https://huggingface.co/mlx-community/granite-4.0-1b-speech-4bit
- https://huggingface.co/ibm-granite/granite-4.0-1b-speech
- https://github.com/Blaizzy/mlx-audio/blob/main/mlx_audio/stt/models/granite_speech/granite_speech.py
- https://huggingface.co/mlx-community/supertonic-3
- https://huggingface.co/Supertone/supertonic-3
- https://github.com/kyutai-labs/hibiki-zero
- https://huggingface.co/LiquidAI/LFM2.5-Audio-1.5B
- https://huggingface.co/nvidia/NVIDIA-NemotronLabs-VoiceChat-11B
- https://huggingface.co/mlx-community/granite-speech-4.1-2b-nar-mlx
