# Local interpreter development preview

September 28, 2026: an independently authored, workspace-bound native preview,
not an installed Nero Voice release or a Teams device. The narrow first path is
Nemotron 3.5 ASR → Hy-MT2 translation → Kokoro speech, all MLX, EN ↔ ES.
This replaces the proposed broad three-model comparison as the immediate work.

## Run on the prepared development Mac

```sh
python3 Workers/Interpreter/test_bounds.py
python3 scripts/package-interpreter-preview.py
```

Open `build/Nero Interpreter Preview.app`. Press **Prepare interpreter**, select
a direction, then **Translate** to use its built-in sample. **Choose audio**
accepts a single track up to 30 seconds / 32 MB. **Record phrase** explicitly
requests microphone access and stops after 29 seconds; press **Translate** after
capture, then **Play translation**. **Stop** cancels processing and playback;
**Prepare interpreter** restarts it. Closing the window quits the preview.

All submitted audio, transcripts, logs and generated speech remain under
`build/interpreter-runs/<request UUID>` for this development evaluation. Explicit
microphone clips are also temporarily saved under `NeroInterpreterPreview` in the
macOS temporary directory. Do not use confidential calls in this developer build.
No live/system capture starts automatically. Playback uses the current Mac output.
No Teams settings, audio drivers or installed Nero packages are changed.

The preview keeps Python libraries warm, but loads and releases each MLX model
sequentially. Its exclusive file lock prevents duplicate preview engines/CLI runs.
That lock does not coordinate with the separately installed Voice app: stop MLX
dictation/meeting processing before trying this development preview. Production
integration must use Voice's shared lifecycle coordinator.

## Reproduce preparation

Use a private Python 3.12 environment at `build/interpreter-venv`; install
`requirements.lock.txt` (including the official spaCy English model URL). Model
preparation is an explicit network step:

```sh
build/interpreter-venv/bin/python Workers/Interpreter/prepare.py
```

`prepare.py` pins the translation and synthesis snapshots and creates local SHA-256
receipts. Runtime validates those receipts and disables Hugging Face network access.
The entire engine and subprocesses run inside a network-denying macOS sandbox.
No model falls back to a hosted provider. Existing ASR comes from the signed Voice
package in `build/latest-package.txt` and the prepared
`build/model-fixtures/nemotron-asr` snapshot; see `docs/MODELS.md`.
Model conversion/runtime configuration is not changed in downloaded snapshots.

| Component | Pinned version |
| --- | --- |
| mlx-lm | 0.31.3 |
| mlx-audio | 0.5.7 |
| misaki | 0.9.4 |
| Hy-MT2 1.8B 4-bit | mlx-community/Hy-MT2-1.8B-4bit, e5c6fe56c7b3bc77fae5ae92db31f2178f1e6912 |
| Kokoro BF16 | mlx-community/Kokoro-82M-bf16, a71e4d38b236d968966a2002c4c895dbd12b1c3c |
| Voices | af_heart (English), ef_dora (Spanish) |

The development Python environment includes spaCy and its dependencies, including
PyTorch for package dependencies; model inference in this path uses MLX. These
packages are not bundled into the released plugin. Model/library redistribution
and the Hy-MT2 license need a separate release review; availability on Hugging Face
is not distribution permission.

## Evidence and limits

`build/interpreter-session-results.json` preserves four serial runs of two
synthetic local speech fixtures. English asks not to send an invoice until Friday;
Spanish states the same constraint. All four recognized and translated the
meeting time, negation and deadline correctly, and produced finite PCM WAVs.
Source fixtures were made with Apple's `say`; synthesis of the translated output
was Kokoro, not Apple Speech.

| Direction | Source duration | Warm-runtime processing, two runs |
| --- | --- | --- |
| EN → ES | 4.19 s | 2.21 / 2.04 s |
| ES → EN | 3.71 s | 4.54 / 2.20 s |

Those numbers sum conversion, ASR, translation and synthesis stage time after a
complete clip is available. They exclude recording time, runtime startup (~3 s),
UI delivery and playback. They are not simultaneous/streaming latency claims.
Earlier cold runs, including a corrected Kokoro model-type lookup failure, remain
in the run directory; later preparation was not substituted into old receipts.

Native preview checks passed for both directions (~2.1 s per phrase), playback
start, Stop during ASR (cancelled receipt and no surviving worker), and restart.
Five boundary tests check long input before conversion, unsupported direction,
receipt overwrite protection, subprocess timeout cleanup and exclusive ownership.
Native UUID case mismatch found during UI acceptance was corrected before handoff.

Two synthetic phrases establish plumbing, not broad translation accuracy. No
accents/noise/overlap, conversational pacing, thermal/power, long meeting, microphone
capture or actual remote caller acceptance is claimed. No voice cloning or speaker
identity preservation. Next: isolated virtual audio bridge and bounded phrase queues,
then a dedicated two-way call using headphones.

## References used for direction, not copied implementations

- [Ora](https://github.com/wuwangzhang1216/ora): local MLX translation UX and latency work.
- [LiveTranslate](https://github.com/NBS282/LiveTranslate): virtual audio cascade architecture.
- [MLX Audio](https://github.com/Blaizzy/mlx-audio): local ASR/TTS runtime.
- [Hy-MT2](https://huggingface.co/mlx-community/Hy-MT2-1.8B-4bit).
- [Kokoro](https://huggingface.co/mlx-community/Kokoro-82M-bf16).

No published component benchmark proves the complete two-way Teams pipeline.
