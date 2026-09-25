# Nero Voice

**Meetings preview (0.3.0):** record a microphone, an exact app audio-process group, or all system audio; pause/resume, bookmark, play and seek saved audio; transcribe locally after recording; optionally prepare the local Sortformer speaker model; correct text and speaker labels; export Markdown. Recording and review work inside the Nook and in Voice's larger window. No separate application or Python installation is required.

The owner has requested newer selectable models. [Model direction](docs/MODELS.md) records Nemotron 3 Diarization, Parakeet/Canary ASR and Kokoro TTS as the next integration, not as already installed providers.

Independent NeroNook voice module for macOS 26 or newer. It adapts the owner's OmniVoice native speech and microphone components; OmniVoice does not need to be installed. NeroNook also continues to work without this module.

## Dictation into other apps (0.2.1)

In Voice settings, choose a shortcut and either **Hold to talk** or **Press to start / stop**, then enable **Insert shortcut dictation at the original cursor**. Allow text insertion in macOS Accessibility. Place the cursor in another app and use the shortcut; wait for Listening before speaking. The floating overlay leaves keyboard focus in that app. Finishing pastes the finalized transcript locally; it never presses Send. Record in the Voice window still produces a draft for review.

Nero Voice captures a non-password text field only when the shortcut starts, then checks the same app, field, text and cursor before insertion. If focus or text changed, the transcript remains recoverable in the Voice window. **Insert draft…** gives you five seconds to click a destination for a reviewed draft. Cancel remains available during that countdown. The overlay offers **Undo insertion** after a confirmed insertion, only while the original field and inserted text/cursor remain unchanged. Use the destination app's own Undo otherwise.

Insertion temporarily replaces the clipboard and restores its previous formats unless another app or the user has changed it meanwhile. Clipboard snapshots are limited to 16 MB. Target text is limited to 128 KB and kept only in process memory for validation/undo; it is never included in the plugin protocol or assistant prompt. Editors that do not expose readable text and selection must use Copy. Paste results are read back; uncertain results are reported and never automatically retried.

This is the first dictation-insertion slice. Selected-text rewriting, automatic cleanup/styles, persistent transcript history, more hotkey choices and broad browser/Electron acceptance remain on the roadmap. The speech engine and existing reviewed Ask path are unchanged.

## Use

Install the signed `.app` through NeroNook Settings → Modules → Install or Update Plugin. Select Nero Voice in the monitor's module list. Open its gear settings, choose your microphone/language and use **Prepare language** if required. Record, then Stop and review the transcript. **Copy** stays local. The standalone window has a larger editable text area. The Nook uses the shared 16:9 stage, separate status line and standard reviewed form.

**Ask** is optional. In NeroNook's Modules settings, allow Nero Voice to use the desired text assistant's action; then choose that assistant in Voice settings. Only reviewed text is sent through the shared SDK. For Nero Agent, this uses its existing ChatGPT connection. Voice does not import credentials or contact a model service directly. Installed-package updates invalidate SDK grants; review and enable the new build's connection again. Spoken replies use installed macOS voices, not ChatGPT conversational Voice.

The dictation shortcut is configurable: Off, Control–Option–V, Control–Option–Space or Control–Shift–V. Hold until the **Listening** indicator appears, speak, then release. Releasing during preparation cancels; it never starts a delayed recording. Record/Stop buttons are available without a shortcut. Close settings to use the shortcut. Personal spellings apply literal whole-term capitalization only, after an explicit button press; Original words restores the unedited recognized text.

**Dictation** stops at 60 seconds or 2 KB of recognized text. Dictation capture is microphone-only and starts from Record or the registered shortcut; no wake word, ambient capture or auto-send. Meetings provides separate explicit system-audio recording. Shortcut dictation can paste locally when insertion is enabled; recording in the Voice window keeps text for review. Transcript and reply remain in memory and clear on process exit. User-requested Copy changes the clipboard; submitted form text is displayed transiently by the host. Device/language/shortcut/spelling/provider preferences are saved in the plugin's own defaults domain. Dictation raw audio is not saved, sent to an assistant or included in protocol messages.

## Meetings

Select **Meetings**, name the session, choose microphone/call audio and press **Start recording**. App choices refer to the exact audio-process bundle shown; some apps expose separate helper groups. Use the explicitly labelled all-system source when appropriate. A missing source stops with an error. Source meters reflect the saved audio. Pause compresses the pause interval out of the recording timeline; bookmarks and both tracks use that same clock.

Stop saves 16 kHz mono CAF chunks per track in `~/Library/Application Support/NeroVoice/Meetings/<UUID>/`. Audio is saved continuously, in roughly 15-second pieces, with recovery for unindexed tails. Limit: four hours, stopping when available disk space drops below 100 MB. Playback mixes the tracks and supports seeking. A headset avoids recording remote speech twice through speaker echo; automatic echo deduplication is not yet implemented.

**Transcribe** runs Apple Speech on saved tracks, with the selected Voice language. Prepare language through Voice settings when needed. It is a post-recording pass, not live captions. **Prepare speakers** optionally downloads a pinned, hash-verified 236 MB model; **Identify speakers** applies local Sortformer analysis. Up to four generic speakers per track; labels are estimates and uncertain/overlapping phrases remain unassigned. Click a timestamp to play; Edit corrects text/assignment, and speaker-name fields rename labels. Original recognized text and audio remain intact. Partial transcript checkpoints survive cancellation; Continue retries an incomplete track. Speaker continuity and accuracy beyond the short fixture require broader evaluation.

The title-searchable library is paginated. Show audio files exposes the recording and transcript JSON; Export transcript writes timestamped Markdown. Move to Trash uses normal recoverable macOS Trash. Nothing is automatically sent to Agent. Live captions, model selection, long-meeting/echo benchmarks, caption export and evidence-linked Agent summaries remain subsequent work.

## Architecture and safeguards

- Own signed application identity and microphone privacy prompt; `launchMode: application` uses the SDK's nonce-authenticated local application channel.
- Own capture, bounded audio conversion queue, speech asset management, recognition and speech synthesis. Vendored SDK snapshot has no build dependency on the host checkout.
- Apple Speech models are system-managed and local. Preparing assets can download from Apple. No silent cloud fallback. The [installation-request API](https://developer.apple.com/documentation/speech/assetinventory/assetinstallationrequest(supporting:)) returning nil means no download is needed; this avoids false negatives from the status query observed on this Mac.
- Analyzer is prepared before microphone capture. Capture uses the selected microphone’s hardware input format; an HDMI output’s different sample rate cannot set the tap format. Listening appears only after actual audio buffers arrive, with microphone name and live input level. A missing/stalled feed stops with an error instead of masquerading as silence. Stop flushes conversion, closes input and awaits final result delivery. Cancellation invalidates the session and rejects late callbacks. Sleep, screen lock and audio-configuration changes stop capture. Preparation/finalization and assistant waits have deadlines.
- Global shortcut handler accepts only its own event signature and ID; no global keyboard monitor. The separate insertion service uses Accessibility for explicit dictation only.
- Assistant discovery structurally requires a read-only `prompt: string` → `reply: string` action with no extra required fields. Exact action definition is pinned at selection. Missing permission, changed provider or disconnection preserves text and cancels the request. Replay IDs are rejected.
- `use_transcript` is a reviewed local-change action; successful acceptance acknowledges Copy/submission, not completion of the separate asynchronous assistant request. Replies/errors appear in the module.

## Development

Requires Xcode/Swift 6 and Python 3 for packaging checks. There is no Python runtime dependency in the installed module.

```sh
swift test
python3 scripts/package.py --identity '<signing identity>'
python3 scripts/check-process.py
```

The app and ZIP are content-addressed under `build`; existing packages are never overwritten. `build/latest-package.txt` identifies the current output. The creator starter's `Tools/nook.py pack` intentionally does not support application-launch packages, so use the plugin-owned script above. No host code change is required. Signing is local development signing; notarization and public licensing are separate release work.

Optional developer-only recognition fixture (no microphone):

```sh
say -o /tmp/nero-voice-fixture.aiff 'Nero Voice keeps my speech on this Mac. These are the last words.'
swift run SpeechCheck /tmp/nero-voice-fixture.aiff
swift run SpeechCheck /tmp/nero-voice-fixture.aiff --capture-pipeline
```

The second run simulates real-time tap buffers through the production converter, bounded queue and finalization path. It does not prove physical microphone, OS permission, device unplug or human dictation quality. See `docs/ACCEPTANCE.md` for observed results. No automatic command execution, advanced dictation cleanup or conversational ChatGPT audio is claimed. Meetings adds a native MLX diarization helper; selected modern providers are tracked separately in docs/MODELS.md.

## Stable local updates

The package script accepts `--identity`, `NERONOOK_SIGNING_IDENTITY`, or the current installed Voice certificate. It rejects missing/ad hoc identities and verifies that the signed update keeps the bundle identity and satisfies the prior package's designated requirement. Signing timeout/failure ends that attempt without retries or temporary-signature fallback. The vendored `scripts/signing.py` helper does not inspect credential values or change Keychain protection.

September 25 packaging-only maintenance: the shared signing tests passed and the real Voice release build signed successfully as `build/cafe.nero.plugin.voice-0.3.0-a1747826a9bd.app`, including its diarization helper, with compatibility against the installed package. No password prompt occurred. Voice audio code and the installed Voice 0.3.0 package were not changed or reinstalled. No new audio/model acceptance is claimed here.
