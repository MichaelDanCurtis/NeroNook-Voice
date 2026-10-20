# Qwen speech and Voice Studio · local Voice 0.21.0

**Qwen Voice Studio…** on the primary Voice card opens a separate native window.
The same button is in Voice settings. It has three independently downloadable
model modes: **Preset voices** (CustomVoice), **Cloned voice** (Base), and
**Describe a voice** (VoiceDesign). Only the selected Qwen model stays loaded.

## Clone a voice

Choose **Cloned voice**, then import 3–30 seconds of clear speech or click
**Record microphone**. Recording uses the microphone selected in Voice settings,
begins only with that button and stops after 30 seconds, on Stop, window close,
Cancel, sleep or shutdown. It does not capture call/system audio or start ASR.
Enter a name and the **exact words spoken in the reference**, then Save voice.

Select the saved voice, prepare the cloning model if necessary, type preview
text and click **Preview Qwen**. Existing recording files are preserved; Nero
stores a private normalized 24 kHz mono reference and transcript on this Mac.
Archive removes a voice from the active list; Undo archive restores it in the
current session. Files remain in the local library's Archived folder.
No training or full model copy is needed for each saved voice. The Base model
encodes the selected reference; its last encoded reference is reused within the
warm worker. It is released with that worker, never uploaded.

## Expression and generation

Preset voices accept a custom style instruction and delivery setting. Describe
a voice accepts a natural-language description, such as a calm female narrator
with a warm lower register. VoiceDesign generates from that description; it does
not establish a permanent speaker identity. Cloning follows the reference
voice; the Swift Base path does not apply style/delivery instructions.

Speaking language can follow Voice or override it for Qwen alone. Advanced
controls expose temperature, top P, top K, repetition penalty, token limit and
audio chunk interval, with bounded values and Reset advanced settings. Top K
zero uses the model's default in the pinned Swift runtime. Token limits can
truncate long passages. Smaller audio chunks trade overhead for responsiveness.

Choose **Nero Voice → Speaking voice → Text to speech → Qwen3 · local voice**.
The same controls are available in **Voice settings → Speech output**. Pick a
Qwen voice, then use **Preview voice**. **Delivery** in settings offers Natural,
Warm & soft and Lower & relaxed. Language follows Voice's selected language;
the voice preset's label describes its native character, not a forced language.

Apple remains the default for a new setup. Switching to Qwen retains the saved
Apple voice, so switching back restores that choice. It does not change speech
recognition, microphone, dictation shortcut or meeting diarization.

## Preparation and resources

**Prepare Qwen** explicitly downloads and verifies the selected optional model (about 3.1 GB),
then loads its local worker without recording or synthesizing. On this Mac the
existing audition weights were verified and reused, so no download was needed.
Selecting Qwen alone does not download weights. Missing assets produce a
preparation message instead of silently using Apple or a cloud voice.

Each optional model occupies about 3.1 GB of disk space (all three total about
9.3 GB decimal). Downloading several does not load them together. The model runs through MLX on Apple silicon and uses more memory and GPU work
than Apple speech. No Neural Engine placement or fan-free operation is claimed.
Prepare loads weights; the first synthesis can still incur kernel setup. A
worker remains warm for up to 60 idle seconds after preparation or generation.
**Release voice** unloads it while retaining downloaded files. Stop cancels the
current utterance; sleep and shutdown also retire work. Another Voice speaking
activity can reclaim an idle Qwen worker; two Qwen model workers are not kept
warm at once.

## Shared use

Agent Talk and the existing Agent/Fuego read-aloud actions use Voice's selected
speech output through the existing generic SDK. They do not implement their
own Qwen runtimes. Conversation audio uses the same playback engine and echo
reference as Apple speech. Audio synthesis is local, with network, microphone
and camera access denied in the worker. The Agent's reasoning provider remains
its separate setting and can still be hosted.

Qwen streams audio instead of waiting for the entire passage. Stop retires
active generation and rejects late chunks. Text is limited to 2 KB and playback
has a 180-second deadline. Supported language choices are English, Chinese,
Japanese, Korean, German, French, Russian, Portuguese, Spanish and Italian;
unsupported locales fail explicitly.

## Local qualification

The final signed helper generated two authored passages, then successfully ran
the existing Nemotron recognition mode in a separate process. Native Preview
reached **Reading aloud** and **Reading finished**. Automated transport tests
cover repeated requests, cancellation and rejected late output. The full Voice
suites pass **141 tests**. File normalization, archive/restore, changed-reference
rejection and persisted option validation have regression coverage. Generated
synthetic references test the cloning path; individual human voice similarity
and physical reference-microphone recording remain separate acceptance checks.

This is a local development build. Sustained Agent/Fuego conversation, acoustic
interruption quality, other languages and clean-Mac distribution remain separate
acceptance checks. See the [delivery record](../reports/qwen-tts-2026-10-17/README.md).
