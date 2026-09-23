# Nero Voice

Independent NeroNook voice module for macOS 26 or newer. It adapts the owner's OmniVoice native speech and microphone components; OmniVoice does not need to be installed. NeroNook also continues to work without this module.

## Use

Install the signed `.app` through NeroNook Settings → Modules → Install or Update Plugin. Select Nero Voice in the monitor's module list. Open its gear settings, choose your microphone/language and use **Prepare language** if required. Record, then Stop and review the transcript. **Copy** stays local. The standalone window has a larger editable text area. The Nook uses the shared 16:9 stage, separate status line and standard reviewed form.

**Ask** is optional. In NeroNook's Modules settings, allow Nero Voice to use the desired text assistant's action; then choose that assistant in Voice settings. Only reviewed text is sent through the shared SDK. For Nero Agent, this uses its existing ChatGPT connection. Voice does not import credentials or contact a model service directly. Installed-package updates invalidate SDK grants; review and enable the new build's connection again. Spoken replies use installed macOS voices, not ChatGPT conversational Voice.

Push-to-talk is configurable: Off, Control–Option–V, Control–Option–Space or Control–Shift–V. Hold until the **Listening** indicator appears, speak, then release. Releasing during preparation cancels; it never starts a delayed recording. Record/Stop buttons are available without a shortcut. Close settings to record. Personal spellings apply literal whole-term capitalization only, after an explicit button press; Original words restores the unedited recognized text.

Recordings stop at 60 seconds or 2 KB of recognized text. Capture is microphone-only and starts from Record or the registered shortcut; no wake word, ambient capture, system audio, auto-send or automatic paste into other apps. Transcript and reply remain in memory and clear on process exit. User-requested Copy changes the clipboard; submitted form text is displayed transiently by the host. Device/language/shortcut/spelling/provider preferences are saved in the plugin's own defaults domain. Raw audio is not saved, sent to an assistant or included in protocol messages.

## Architecture and safeguards

- Own signed application identity and microphone privacy prompt; `launchMode: application` uses the SDK's nonce-authenticated local application channel.
- Own capture, bounded audio conversion queue, speech asset management, recognition and speech synthesis. Vendored SDK snapshot has no build dependency on the host checkout.
- Apple Speech models are system-managed and local. Preparing assets can download from Apple. No silent cloud fallback. The [installation-request API](https://developer.apple.com/documentation/speech/assetinventory/assetinstallationrequest(supporting:)) returning nil means no download is needed; this avoids false negatives from the status query observed on this Mac.
- Analyzer is prepared before microphone capture. Stop flushes conversion, closes input and awaits final result delivery. Cancellation invalidates the session and rejects late callbacks. Sleep, screen lock and audio-configuration changes stop capture. Preparation/finalization and assistant waits have deadlines.
- Global shortcut handler accepts only its own event signature and ID; no global keyboard monitor or Accessibility-based typing.
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

The second run simulates real-time tap buffers through the production converter, bounded queue and finalization path. It does not prove physical microphone, OS permission, device unplug or human dictation quality. See `docs/ACCEPTANCE.md` for observed results. No automatic command execution, local MLX provider, advanced cleanup, automatic target insertion or conversational ChatGPT audio is claimed in this slice.
