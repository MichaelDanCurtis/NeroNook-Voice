# Local meeting quality candidate 0.22.2

See the [local measurements and retained failures](../../NeroNook/reports/voice-meeting-reliability-2026-10-21/README.md).

- Attach a bounded opening feed before capture; recognition consumes the same
  audio after model preparation, with explicit overflow and independent storage.
- Shared 40 ms edge timing at the unchanged 0.50 Nemotron threshold. Preserve
  per-track identities, overlap, monotone commitment and final flush.
- Separate weight revision from `+edges40ms-v1` attribution revision. Never
  replace a corrected turn's speaker just because its old reviewed flag is false.
- Preserve the existing summary generator. Three attempted alternatives failed
  ownership/cancellation/recall checks and were excluded from the package.

180 Swift tests, nine Python tests, web/protocol checks, real isolated workers,
independent scoring and signed package/extracted-ZIP checks pass. This is not
installed, notarized or published; no host/SDK or account/grant changes.
