# Nero Voice

**Planned expansion:** the owner requested meeting recording and speaker diarization alongside the dictation product. [Meeting scope and OmniVoice assessment](docs/MEETINGS.md) cover source selection, durable audio/playback, speaker correction, local providers and optional Agent summaries. The installed 0.2.1 behavior below remains microphone-only short dictation; meetings are not implemented yet.

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

Recordings stop at 60 seconds or 2 KB of recognized text. Capture is microphone-only and starts from Record or the registered shortcut; no wake word, ambient capture, system audio or auto-send. Shortcut dictation can paste locally when insertion is enabled; recording in the Voice window keeps text for review. Transcript and reply remain in memory and clear on process exit. User-requested Copy changes the clipboard; submitted form text is displayed transiently by the host. Device/language/shortcut/spelling/provider preferences are saved in the plugin's own defaults domain. Raw audio is not saved, sent to an assistant or included in protocol messages.

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

The second run simulates real-time tap buffers through the production converter, bounded queue and finalization path. It does not prove physical microphone, OS permission, device unplug or human dictation quality. See `docs/ACCEPTANCE.md` for observed results. No automatic command execution, local MLX provider, advanced cleanup or conversational ChatGPT audio is claimed in this slice.
