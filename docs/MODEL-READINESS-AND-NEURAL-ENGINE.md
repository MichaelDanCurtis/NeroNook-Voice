# Model readiness and the Neural Engine

## October 17 measured pilot

The local three-way comparison is complete: [results and limits](../../NeroNook/reports/asr-ane-2026-10-17/README.md). Identical 36-file human corpus, three rotated paced rounds, no microphone/network access. Clean WER Apple 3.5%, Nemotron MLX 3.8%, EOU Core ML 5.2%; first changed words 4.02, 1.09 and 1.01 s in this harness. Instruments confirms actual EOU encoder ANE activity; decoder and joint decision prefer CPU. Attributed process memory and GPU-rail load favour EOU over the current Nemotron adapter, but do not establish full model RAM or reliable total watts/fan behaviour.

EOU is not installed as a Voice backend. Its default 1280 ms debounce produced native confirmation in 9/12 paced probes, median 1.99 s after original file end; three did not confirm within the two-second tail. Keep live-word speed separate from endpoint delay. Apple required an end-of-input adapter for this benchmark; continuous product boundary behaviour remains a separate gate. The initial accelerated Nemotron queue overflow was repaired only in the isolated harness using backpressure, then the entire corpus was repeated with unchanged weights/questions.

Next: independent optional Core ML adapter, readiness/cancellation correctness, lower-debounce pause/false-cut trials, quiet Nemotron signal/boundary diagnosis, and natural microphone/meeting/Agent acceptance. Preserve current engines and selection. No live capture or installed app changes occurred in this pilot.

## October 16 implementation record

October 16, 2026. Voice 0.19.4 / Agent 0.5.4, local development only.

## What works now

Agent's primary **Agent model** picker loads the models offered by its existing,
isolated managed account. It does not import providers, keys or desktop settings.
The explicit selection applies to the next interactive text or spoken request;
SDK meeting/evidence requests retain their existing policy. Switching is disabled
during a reply. An unavailable saved model fails visibly; it does not fall back
silently. **Account default** restores the runtime's default model choice.
Catalog pagination and display pages are bounded. Reading that catalog does not
send a prompt or preload hosted weights; hosted model residency is outside our
control. The existing account connection starts before a request when signed in.

Voice's primary card keeps its **Speech to text** selector: Apple Speech,
Nemotron 3.5 MLX and Parakeet v3 MLX. It also offers **Prepare conversation**.
This loads the installed selected recognizer without opening an audio engine,
microphone or system capture. Talk consumes that exact prepared instance once.
Model, language and helper path must match. Used recognizers are never returned
to the cache, so audio/results from a prior session cannot enter a new one.

The preparation expires after two idle minutes. **Release prepared model**, model
or language changes, sleep/lock, cancellation and shutdown release it. Other
MLX tasks retire the idle lease before taking the single process slot. Preparation
is explicit: no launch/hover recording, automatic downloads, synthetic audio or
background inference. It is a Talk preparation in this iteration; dictation and
meeting launches release it rather than claiming they reuse its state.

The first prepare still takes time and holds model memory while ready. It moves
loading ahead of Talk; it does not eliminate inference, device routing, hosted
reply latency, or all first-use graph compilation. Native Parakeet preparation
and release worked; a file-fed Nemotron trial reused the warmed recognizer and
kept both original phrases. Physical conversation and energy qualification remain.

## Where the Neural Engine fits

The [MLX framework](https://mlx-framework.org/) targets CPU/GPU execution. Our
current MLX speech workers therefore do not acquire ANE placement from a toggle.
A separate Core ML runtime/model path is required. Apple's
[cpuAndNeuralEngine](https://developer.apple.com/documentation/coreml/mlcomputeunits/cpuandneuralengine)
configuration excludes the GPU but still permits CPU execution; it is not an
ANE-only guarantee. Apple's own speech framework and TTS do not expose this
per-model compute-unit control to our app.

| Candidate | Why test it | Limits before adoption |
| --- | --- | --- |
| Current Apple Speech | Existing native baseline and local language assets | OS-controlled placement; measure it rather than infer an ANE percentage |
| Current Nemotron MLX | Preserve our present streaming/correctness baseline | CPU/GPU runtime; no ANE setting |
| Parakeet Realtime EOU 120M Core ML | Smaller streaming model with explicit utterance completion | English-only; shorter chunk setting has an accuracy tradeoff; Core ML integration and this Mac's measurements pending |
| Nemotron Core ML | Compare a similar streaming model through an ANE-capable runtime | The published 3.5 multilingual conversion currently requests gated access; no weight download or approval has been attempted |

The [Parakeet EOU model card](https://huggingface.co/FluidInference/parakeet-realtime-eou-120m-coreml)
reports M2 LibriSpeech test-clean WER of 8.29% at 160 ms chunks versus 4.87% at
320 ms. Those are upstream results, not Nero results or complete conversational
latency. Start with the 320 ms variant for the bounded comparison. Its weights
carry NVIDIA's Open Model License; the
[FluidAudio SDK](https://github.com/FluidInference/FluidAudio) is Apache-2.0,
and model redistribution remains a separate review before distribution.
The [Nemotron 3.5 conversion card](https://huggingface.co/FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML)
documents its access requirement and variants. No new dependency, weights or
Core ML speech engine have been installed by this iteration.

## Original comparison plan (October 16)

Pin runtime and weight revisions, then compare current MLX Nemotron, Apple Speech
and Core ML Parakeet EOU 320 ms on the same authored corpus: ordinary speech,
hesitations/corrections, quiet words, noise and two-speaker overlap. Keep held-out
audio separate. Use one model at a time. Report cold preparation, warm activation,
first/final words, utterance end delay, WER, memory and sustained power/thermal
behavior. Include warm/idle-release behavior and microphone permission-off tests.

For Core ML, inspect the
[compute plan](https://developer.apple.com/documentation/coreml/mlcomputeplan-1w21n)
for anticipated device placement, then profile actual inference. A supported
configuration or a published ANE claim does not establish actual placement,
lower power, fan silence or better accuracy on this Mac. Adopt an optional
backend only after the measured tradeoff is worthwhile; preserve the current
recognizers and independent Voice/plugin boundary.
