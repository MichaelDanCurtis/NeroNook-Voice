# Live speaker-output reliability · local candidate

Live Nemotron speaker updates now enter a bounded ordered reader before MainActor delivery. The old separate-task-per-chunk path did not bound output waiting while the UI was busy. The existing short-ready pipe behavior remains, with accepted data copied into at most64 queued chunks of16KiB. Oversized input/overflow explicitly disables optional live attribution; saved audio remains available. This is a queue bound, not an RSS or cancellation-deadline guarantee.

One decoder handles partial lines and final updates in order. EOF without the worker’s closed record is reported; finalization waits for the actual reader after process exit. Queued and synchronous Stop retire later updates. Model/thresholds, Room/Call clocks, anonymous identity, manual corrections, one-model policy and recording defaults remain unchanged.

Normal ModuleApp build and16 focused checks pass: six new real-pipe/authored-worker cases, six existing startup/Pause-Resume continuity and four attribution cases. Synthetic saved PCM is preserved. No live capture, real model inference, WER/DER, full225-suite, power or installed acceptance is claimed. The owner’s recording trial has not been run. Voice0.22.6 remains installed.

Existing449-file working SDK was compiled unchanged; the previously deferred WebSurface mirror difference was not synchronized or adopted. No cloud, account/grant, SDK/wire, service/public, signing/notarization or paused-work change. Builds stay local; host releasefloor0.35.0 remains.

[Results, scope and original evidence](../reports/meeting-speaker-output-2026-10-31/RESULTS-001.md).
