# Meeting folders and recording imports · Voice 0.15.1

## Use

In Meetings, use the folder selector beside **…** to show All meetings,
Unfiled, or one folder. **…** opens New folder, Rename, Remove folder and
Undo last change. Removing a folder puts its meetings in Unfiled; it never
removes their audio, transcript, calendar link, notes or chat. Each recording
has a **Folder** selector. New recordings and imports enter the selected folder.

**Import recording** opens a native file picker. Select one audio file or video
recording. A progress strip has Cancel. Nero Voice creates an owned audio copy;
the source remains unchanged. Re-selecting identical imported bytes opens the
existing recording and preserves its folder assignment. Imported audio remains
playable even if the original is later moved. Video images are not stored.

Choose your local speech model and **Transcribe** after importing. Import does
not start recognition, record the microphone, or send audio to a service.
Imported recordings work with local speaker analysis, corrected transcripts,
notes, explicit calendar links, per-recording chat and cited library questions.
The chosen folder scopes library question retrieval and eligible recent chat
context; the shared library chat history remains available.

## Storage and limits

- `folders-v1.json` is logical UUID membership, up to 40 uniquely named folders
  (80 UTF-8 bytes each) and 10,000 assignments. One validated previous arrangement
  supports Undo. Recordings retain their original UUID paths and source identities.
- Import supports audio formats decodable by Apple's AVFoundation, including
  verified WAV/CAF, AAC M4A and audio inside MP4 video. Unsupported/encrypted media
  fails explicitly. Other codecs depend on the native decoder; no full format
  parity is claimed.
- One file at a time, up to 2 GB and four hours, with at most eight audio tracks.
  Audio tracks are mixed into one 16 kHz mono float CAF stream, in 15-second chunks.
  The imported clock starts at zero and follows decoded samples; video timestamps,
  original track identity, video and metadata are not retained. Native resampling
  can round a sub-millisecond tail (three samples in the 48 kHz fixture).
- Streaming decode and incremental hashing keep memory bounded. Input modification,
  cancellation, unreadable audio and insufficient free space reject publication.
  A hidden unique staging folder is published only after every CAF and sidecar
  closes and validates. Ordinary failure removes its own staging folder. A crash
  can leave hidden staging; the library never treats it as a saved recording.
- `import-v1.json` stores filename, size, SHA-256, import time and meeting UUID;
  no original absolute path or account credentials. Existing recordings need no
  migration. No SDK action, permission or host implementation change.

## Verification

See [delivery evidence](../reports/library-imports-2026-10-13/README.md).
76 Voice tests cover folder persistence/removal/Undo, source/citation retention,
corrupt and linked metadata, folder-scoped context, native audio normalization,
owned playback after original removal, AAC duplication, real MP4 video audio,
mid-decode cancellation and invalid sources. Frontend checks cover folder controls,
confirmation, progress and state locks. Native installed acceptance is recorded
separately; a successful build alone is not a recording or ASR acceptance claim.
