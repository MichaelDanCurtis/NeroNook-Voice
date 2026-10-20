# App styles, snippets and local history · Voice 0.16.3

## Everyday use

The Dictate card and larger Voice window share **Dictate**, **App styles**,
**Snippets** and **History**. The speech recognizer and shortcut are unchanged.

- **Default style** on the primary card sets Clean, Formal or Literal. In App
  styles, search a running/saved app or Choose another app, choose its style and
  Save app style. Use default removes the override. The global shortcut resolves
  the actual destination app's bundle identity at press, freezes that rule,
  dictionary and snippet list, then pastes into the same app/window on release.
  The caption identifies the app and applied style. Neither its field contents
  nor window title is saved in these settings.
- In **Snippets**, name reusable text and save it. Say **insert snippet** followed
  by that name, alone or within a sentence. Ordinary mentions never expand.
  Longest matching names win; at most eight expansions per dictation. A standalone
  snippet bypasses grammar/model editing and inserts exactly the saved text,
  including newlines and symbols. Embedded snippets use protected markers; literal
  bodies never enter the polishing model. Changed/unknown/duplicated/reordered
  markers reject model output and use deterministic cleanup. Snippets never expand
  recursively. Names may be Unicode; the command prefix is currently English.
  **Use in draft** loads it for review/Copy without pasting.
- **History** starts off. Enable Save completed dictation and choose 1, 7 or 30
  days. Up to 200 completed recognitions retain recognized/final text, date,
  recognizer, captured app name/ID, applied style and Draft ready / Paste sent /
  Paste failed outcome. Paste sent is a delivery attempt, not proof that an
  arbitrary app accepted the text. No audio or field/window content is stored.
  **Load as draft** restores final text and its original recognized words without
  pasting or submitting it. Manual edits/style previews are not added to history.
  **Erase local history** asks before permanently removing it. Turning saving off
  prevents future saves; existing entries expire or can be erased explicitly.

**Apply style & snippets** processes your edited draft locally using the selected
app in App styles (or the default when none is selected). The primary label says
Draft preview; it does not substitute that selection for the real shortcut target.
Clean/Formal use Apple's language model when available, with a five-second bound
and deterministic fallback. Formal quality therefore depends on local model
availability and response; Literal skips grammar polishing. Snippet spelling and
symbols remain exact. A 2 KB output limit applies; overflow leaves the original
recognition recoverable instead of sending a partial expansion.

## Persistence and privacy

Own private `NeroVoice/Dictation` directory; `personalization-v1.json` contains up
to 100 unique app rules and 100 unique named snippets. Names are limited to 60 UTF-8
bytes / eight words and each body to 2 KB. `history-v1.json` exists only after an
opted-in completed result (or an explicit QA fixture). Files are owner-only.
History prunes at launch, page open, save and about once per minute while idle;
closed-app expiry is applied on the next launch. Settings corruption is reported
and preserved; no silent reset. Clear history refuses symlink/outside storage.
The capture-start consent identity must still match at completion; switching off
saving during a recording invalidates it. Cancelled or failed recognition does
not create a completed entry; insertion failure retains a usable draft.

No new SDK action exposes history/snippets; no assistant call, new account,
Keychain credential, cloud audio service or model download is introduced. Existing
meeting, Agent, calendar and Fuego speech features remain independent. History is
shown to the local host only when you open that view, and is not automatically
sent to a conversational provider.

## Verification

[Installed evidence](../reports/dictation-personalization-2026-10-13/README.md)
records 84 tests, signed SDK/process checks, frontend regression checks and native
style/snippet/history UI. Synthetic owned text was used; no live microphone,
user field capture or cloud request. Repeated physical press/speak/release checks,
ASR phrase recognition across accents, long everyday use and full Wispr parity
remain acceptance work.
