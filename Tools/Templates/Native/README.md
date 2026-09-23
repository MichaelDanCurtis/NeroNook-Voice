# Your independent Nook module

This project builds without the NeroNook app or its source checkout. Its versioned SDK snapshot is vendored in `Vendor/NookPluginSDK`; `SDK-SNAPSHOT.json` records every source hash. Requires macOS 14+, Swift 6/Xcode and Python 3 for development tools. The packaged module has no Python dependency.

```sh
python3 Tools/nook.py validate .
python3 Tools/nook.py test .
python3 Tools/nook.py dev .
python3 Tools/nook.py dev . --replay Fixtures/replay.json
python3 Tools/nook.py pack .
```

`dev` opens a standalone preview. Stop it by quitting that app; edit code and rerun `dev` to rebuild. It does not automatically install, grant permissions or replace a running plugin. `test` runs your project tests, then the actual packaged process against modern and legacy fake hosts: handshake, SDK-validated messages, timed snapshots and connection-close exit. It does not invoke module actions. `--replay` is a starter-owned demo sequence, not a host feature. Protocol diagnostics never print payload values or captured stderr; compiler output remains ordinary developer output.

In NeroNook 0.14+, use Settings → Modules → Install or Update Plugin and choose the `.app` printed by `pack`. Inspect the same module on each monitor. The true shared surface is 16:9 with a separate single-line status and module selector. The standalone preview illustrates these dimensions but does not replace host acceptance.

Change `Sources/ModuleCore/Dashboard.swift` to supply data and actions, `Sources/ModuleApp/ModuleApp.swift` to own lifecycle/setup, and `Resources/NookPlugin.json` to describe the actual capabilities. The demo counter is memory-only, shared across displays and reset on restart. Reset uses in-card confirmation. The shared action bus exports only `read_status` plus expiring state; external changes need correctly classified actions and domain checks before execution. Unknown/offline actions do nothing. Test replay never writes saved preferences or touches hardware.

Keep connection/authentication in the gear settings, content in useful tabs, and ordinary controls in the Nook. Your plugin owns secrets, network clients, state and domain validation. Do not add integration code to NeroNook. Use `PluginApplicationChannel` and your own platform-specific packaging if your framework needs the application-launch transport; this simple starter intentionally uses stdio.

Packaging produces a new content-addressed app and archive for each changed build; previous versions remain available for manual reinstall through the host's normal review. No automatic rollback, publisher trust or notarization is claimed. Ad hoc signing is local development only; `--identity` selects a specific signing identity. Add your own entitlements, assets and distribution pipeline deliberately before publishing. The starter has no network/device/privacy entitlements.

This is a local developer preview. No SDK/examples redistribution license has been selected. Do not publish the kit or invite outside creators until its owner chooses that license and distribution checks are complete.
