# Meeting input and speaker coverage · local 0.22.4

Live Parakeet and Nemotron now keep the most recent 350 ms of quiet audio before
an energy-triggered phrase. The selected recognizer receives that prefix once,
with its original clock. This helps retain soft opening syllables without
starting the model on silence alone. Each source retains at most 5,600 float
samples (22,400 payload bytes); Room and Call queues remain independent. Explicit
turn boundaries and capture discontinuities discard the prefix. Neither a new
model nor a lower speech threshold is introduced. Entirely sub-threshold speech
can still be missed; saved audio remains available for later transcription.

Speaker attribution uses genuine word timing when present and ordered. Coverage
is measured over the words, rather than the silence in their containing phrase.
Someone speaking only in the gap cannot claim those words. The existing dominant
coverage and competing-speaker gates remain; overlapping voices stay unassigned.
Absent, zero-duration, overlapping or backwards word timing falls back to
conservative phrase-level coverage. Manual corrections/names remain protected.
The policy revision is recorded separately from model weights so an explicit
saved-audio analysis can refresh older automatic labels.

Verification uses local cached public speech, authored timing cases and the
full Swift suite. On six readers' clean/quiet paired LibriSpeech passages (182
reference words over twelve files), live-worker word errors fell from 23 to 13
for Parakeet and from 17 to 9 for Nemotron. This is a small, previously used
development sample of read speech, not a new held-out meeting benchmark. No
individual clip regressed in this subset; see the retained per-clip results. No model weights,
thresholds or reference answers were tuned to these outputs. The final release
helper reproduced the debug candidate’s word-error totals. Different cache/load
conditions mean the retained wall times do not qualify a speed comparison.

The speaker changes fix demonstrated attribution logic; they do not establish a
new diarization-error rate or recognition of real names. Far-field audio, echo,
overlapping speech, live Teams and long meetings still need acceptance checks.
Apple Speech and the chosen models/defaults remain available. Everything is local;
no audio upload, ambient capture, hosted inference or public release is involved.

Detailed inputs, predictions, baseline failures and build/test receipts:
`reports/meeting-coverage-2026-10-28/` (local/ignored).
