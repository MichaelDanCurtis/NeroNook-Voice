# Selectable local audio models

September 24, 2026. Owner direction: use more recent models through [MLX Audio](https://github.com/Blaizzy/mlx-audio), particularly [Nemotron 3 Diarization](https://huggingface.co/mlx-community/Nemotron-3-Diarization), Parakeet or Canary ASR, and Kokoro speech output.

This is the next implementation direction. The installed 0.3.0 baseline currently uses Apple Speech, optional four-speaker Sortformer, and installed macOS TTS voices. The providers below are not yet selectable or benchmarked in Nero Voice.

## Recommended roles

| Role | First candidate | Why evaluate it |
| --- | --- | --- |
| Speaker separation | Nemotron 3 Diarization | Eight speakers, overlapping speaker activity, streaming state, 10 ms output frame resolution. NVIDIA released it September 23, 2026. |
| General transcription | Parakeet TDT 0.6B v3 | Local transcription across 25 languages with word timestamps in the model family; evaluate latency and terminology accuracy against Apple Speech. |
| Translation and alternate ASR | Canary 1B v2 | Transcription and translation; preserve original-language transcript separately. Verify timestamp/alignment support in the chosen implementation. |
| Spoken replies | Kokoro 82M | Compact local speech with preset voices and speed control. Evaluate first-audio latency, pronunciation, interruption and long replies. |
| Streaming dictation comparison | Nemotron streaming ASR | MLX Audio also supports native streaming ASR models; compare against Parakeet rather than assuming streamed tokens imply a true continuous microphone decoder. |

The recommendation is based on documented capabilities, not a claim that these models have already outperformed the baseline on this Mac. Nemotron's 10 ms is timestamp resolution, not end-to-end latency. NVIDIA documents 0.32-second input buffering as its lowest recommended mode, excluding compute time.

## Provider architecture

Keep recording, saved tracks, timestamps, review and export independent from model choice. Add separate Transcription, Speakers and Speech output selectors behind Voice settings. Show download size, model/runtime version, language coverage, speaker ceiling, readiness and the option to remove downloaded assets. Prepare explicitly, verify pinned revisions/checksums, and offer updates with rollback. Never silently switch an active recording to a new model.

Record provider ID, exact model revision, processing mode and language in each transcription run. Reprocessing produces a new result while preserving original audio and manual corrections. Distinguish provisional live results from finalized text and speaker turns. Maintain session-wide speaker state, flush the final partial chunk/lookahead, retain overlap and do not infer people's names.

The audio runtime belongs to the independent Voice package. NeroNook only hosts generic SDK views/actions. No user-managed Python, terminal server, OmniVoice installation or dependency on Nero Agent. For initial Nemotron support, a private packaged MLX Audio Python worker is a practical candidate; native Swift support can replace it behind the same contract once verified. A managed runtime download may be necessary to stay inside the current plugin package size limit. It must be reproducible and self-contained, not an arbitrary pip installation at runtime.

The Swift package inspected at 01dec7c9bdce3088a6b6b7ab9f2e403458195efb has Parakeet, Canary and Kokoro implementation sources, but its VAD module does not include the new Nemotron diarization architecture. The existing Sortformer helper cannot load Nemotron merely by changing the model URL. Python MLX Audio currently documents the specific Nemotron loader and live-feed finalization API.

Agent may discover a generic local Speak action through the SDK when Voice is installed. Both plugins must still run independently; no duplicated account authentication and no automatically shared meeting audio/context.

## Verification before choosing defaults

Use identical consented/test audio for provider comparisons: accents, names/technical terms, pauses and sentence endings; two, four, and five-to-eight speakers; overlapping speech; room versus headset audio; long recordings and interruption/restart. Measure transcription errors, speaker assignment errors, word/speaker timing, latency to first/final words, first spoken audio, peak memory, processing time, battery and cancellation. A valid output array is only an integration check.

## Primary references and inspected model revision

- [Nemotron model card and MLX feed API](https://huggingface.co/mlx-community/Nemotron-3-Diarization), inspected revision 59ed2dbfc1346dcea9d423c71306a3a2499c568f; weights 198,632,220 bytes, SHA-256 21e8427d1795c9c46c5800f56b16061734ffd0dcadd71d9bcf0b4d6ef7261da5. Not downloaded or run here.
- [NVIDIA Nemotron description and latency configurations](https://huggingface.co/nvidia/Nemotron-3-Diarization).
- [NVIDIA Parakeet v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) and [MLX conversion](https://huggingface.co/mlx-community/parakeet-tdt-0.6b-v3).
- [MLX Audio Canary implementation](https://github.com/Blaizzy/mlx-audio/tree/main/mlx_audio/stt/models/canary).
- [Kokoro model card](https://huggingface.co/hexgrad/Kokoro-82M) and [MLX Audio](https://github.com/Blaizzy/mlx-audio).
