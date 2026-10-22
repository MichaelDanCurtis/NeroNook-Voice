**October 21 · local 0.22.2 candidate:** opening audio queues before recognition
preparation; 40 ms speaker edge timing reduces missed speaker time by 13.49%
across three short public AMI windows. 180 Swift / nine worker tests, independent
NIST, actual isolated live/file workers and signed package/ZIP checks pass.
Manual corrections retain their labels. Three notes-generation candidates
regressed and were excluded; the existing summarizer stays unchanged. Not
installed, notarized or published; host/SDK, accounts and grants unchanged.
[Evidence and limits](../NeroNook/reports/voice-meeting-reliability-2026-10-21/README.md).

**October 20 · Voice 0.22.1 installed locally:** meeting notes open as readable
summary/decisions and source-linked action cards. Editing stays behind disclosures;
old/manual notes retain their editor. Current-commitments generation is included;
a stricter typed-extraction experiment regressed and was excluded. Shared SDK
Light/Dark/compact review, 177 Swift checks, web/protocol checks and installed
Running/signature/continuity pass. No speaker model/default or public changes.
[Delivery and limitations](../NeroNook/reports/voice-meeting-actions-2026-10-20/README.md).

**October 20 · Voice 0.22.0 installed locally:** physical TextEdit shortcut,
replacement and immediate Undo pass. Specific pre-write failures support explicit
retry; uncertain writes do not. Chrome/Electron acceptance remains incomplete.
177 Swift checks, web regressions, signed protocol and installed Running status
pass. Preferences, placement and 36 access definitions are retained.
[Installed evidence](../NeroNook/reports/voice-022-acceptance-2026-10-20/README.md).
Meeting-note quality improvements and a measured human-speaker baseline are
separate uninstalled work: [results](../NeroNook/reports/voice-meeting-quality-2026-10-20/README.md).

# Nero Voice
Independent native voice plugin. Read README.md. Keep microphone, recognition, hotkeys and speech synthesis here, not in NeroNook. Use only the shared SDK for optional conversational providers; no account/token imports. Local Apple Speech first; no silent cloud fallback. The owner authorized Meetings, including explicit microphone/system-audio recording, saved audio and diarization; see docs/MEETINGS.md. No ambient recording or wake word. Start recording only from a direct user control. Preserve editable transcript review before copying/sending. Bound audio queues and duration, serialize lifecycle, reject late callbacks and stop on shutdown/sleep. Maintain OmniVoice provenance. No automatic subagent delegation.
