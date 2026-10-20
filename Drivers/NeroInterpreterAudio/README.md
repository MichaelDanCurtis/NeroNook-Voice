# Nero Interpreter Audio 0.1 — development driver

September 30, 2026. Two isolated virtual duplex routes for the independent Voice
plugin. No printer, audio-driver or model implementation is added to NeroNook.
The local phrase translator remains separate until the real HAL transport gate passes.

| Route | Meeting app uses | Interpreter will use |
| --- | --- | --- |
| Nero Interpreter Speaker | Output (Spanish from meeting) | Input for incoming speech translation |
| Nero Interpreter Microphone | Input (translated Spanish) | Output for synthesized outgoing speech |

Both devices expose an input and output because they are independent loopback
cables. Their buffers never connect to each other. Fixed stereo 48 kHz native
Float32; the future bridge converts model audio rates. Neither device is eligible
as the default system audio device. No raw-microphone bypass exists in this driver.

## Current gate

- Signed arm64 driver and bridge-check helper built; signature verified.
- Real driver object/stream construction, fixed rate and custom property tested
  in process. Ring tests cover exact samples, route isolation, Stop, expiration,
  restart, timestamp wrap, nonfinite/clipped input and concurrent access.
- Live Core Audio query correctly reports not installed before installation.
- Native preview has Install audio driver, Refresh and Check audio bridge controls.
- Initial installation succeeded September 30 at 10:55 PDT; receipt and matching signed binary verified. Repeat attempt correctly refused overwrite.
- Core Audio has not restarted since installation; device enumeration remains pending. The corrected preview distinguishes installed from loaded.
- **Actual HAL loading, live loopback, Teams selection and translation-to-Teams are
  not verified yet. Do not use the virtual routes for a real meeting.**

Evidence: `build/interpreter-audio-build.log`,
`build/interpreter-audio-package.log`, `build/interpreter-audio/package-receipt.json`.

## Transport contract

`TimedRing.hpp` is original code. The single mixed writer stores absolute frame
tags and a session generation beside atomic samples. Readers return silence for
missing or overwritten tags. Input trails output by 2,048 frames (~42.7 ms at
48 kHz), advertised as input-stream latency. There is no disk, network, allocation
or mutex in the Nero ring/callback code. The upstream libASPL dispatcher has its
own IO serialization mutex; this is not a claim that all of Core Audio is lock-free.

A Core Audio CFString custom property, selector `nrle`, accepts `renew-v1` or
`stop-v1`. Renewal enables a route for 500 ms using the monotonic clock; the bridge
must refresh it more frequently. Stop advances the generation and silences reads.
An expired renewal also advances the generation before reopening; old speech is
not replayed. The property is a liveness/control mechanism, not authentication.
Like other local virtual audio devices, other permitted local clients can use it.

The driver stores at most 32,768 stereo frames per route. It performs no inference,
translation, microphone capture or network IO. The user-space bridge will own
phrase segmentation, model scheduling, input/output selection, queue bounds and
translation errors. Inference success must never be inferred from audio-driver
presence. Continuous two-way throughput remains unmeasured.

## Build and installation

```sh
build/interpreter-venv/bin/python Drivers/NeroInterpreterAudio/build.py
python3 Drivers/NeroInterpreterAudio/package.py
python3 scripts/package-interpreter-preview.py
```

Build uses vendored libASPL commit `633e0f70203edd87d320fc5a3cae901e1363aac5`, its
retained MIT and Apple notices, Python/Jinja2 for its code generation, and Xcode's
system frameworks. No Homebrew library is dynamically linked into the driver.
Code is signed using the existing stable Nero development certificate. The installer
container is local/unsigned; this is not a notarized/public distribution.

Install `build/interpreter-audio/NeroInterpreterAudio-0.1.0.pkg` through Installer.
It adds only `/Library/Audio/Plug-Ins/HAL/NeroInterpreterAudio.driver` and its package
receipt. It refuses to overwrite any existing driver at that path; relocation is
disabled. Administrator authentication is required. It does not restart Core Audio,
reboot, change default devices, configure Teams or start a recording. If Refresh
still reports not loaded, restart the Mac when convenient after saving your work.

After loading, use **Check audio bridge** in the preview, or:

```sh
build/interpreter-audio/NeroBridgeCheck --list
build/interpreter-audio/NeroBridgeCheck --self-test
```

The test targets only the two exact Nero device UIDs. It refuses an already active
route. Synthetic signals check default silence, distinct sample levels on each
route, explicit Stop, missing heartbeat and restart; no physical microphone or
speakers are selected and no default route is changed. A passed in-process test
is not a substitute for this live test. The native helper has a 15-second deadline.

## Reversible removal

Quit the preview and any app using these devices. Move only
`/Library/Audio/Plug-Ins/HAL/NeroInterpreterAudio.driver` to a backup directory
outside HAL using Finder (administrator approval), then restart when convenient.
The bundle can be restored from that backup. Do not remove or restart other vendors'
drivers. Installed Nero Voice 0.8.0 does not depend on this optional preview driver.

## Upstream references

- https://developer.apple.com/documentation/coreaudio/creating-an-audio-server-driver-plug-in
- https://github.com/gavv/libASPL (MIT; retained licenses in Vendor/libASPL and driver Resources)

The optional HAL driver stays a Voice-owned component with its own build and install
path. Existing dictation and saved-meeting functions retain their current release.
