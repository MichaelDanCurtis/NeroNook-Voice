**October 20 · Voice 0.22.0 source candidate:** selected-text rewriting stays
separate from Fn dictation, recording, meetings and agent actions. One shortcut
captures before review activation; local-only generation, exact AX replace/Undo,
no whole-field or clipboard fallback. Keep installed 0.21.12 until real editor
acceptance. [Usage and limits](docs/SELECTED-TEXT.md).

# Nero Voice
Independent native voice plugin. Read README.md. Keep microphone, recognition, hotkeys and speech synthesis here, not in NeroNook. Use only the shared SDK for optional conversational providers; no account/token imports. Local Apple Speech first; no silent cloud fallback. The owner authorized Meetings, including explicit microphone/system-audio recording, saved audio and diarization; see docs/MEETINGS.md. No ambient recording or wake word. Start recording only from a direct user control. Preserve editable transcript review before copying/sending. Bound audio queues and duration, serialize lifecycle, reject late callbacks and stop on shutdown/sleep. Maintain OmniVoice provenance. No automatic subagent delegation.
