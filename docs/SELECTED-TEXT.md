# Selected-text editing · local 0.22.0

This is a separately invoked Voice capability, not an agent action or a new
dictation mode. Version 0.22.0 is installed locally. No public package or catalog
update is authorized.

Highlight text in another app, then press **Control–Option–R** once. The shortcut
captures the selection before opening the review window. Choose Rephrase,
Clarify, More formal, More friendly or Improve writing, then **Generate preview**.
Review or edit the result and choose **Replace selection**. Cancel changes
nothing. The window returns focus to the original app on explicit dismissal;
expiry, sleep and shutdown never bring another app forward automatically.

**Voice settings → Selected-text editing** records another modified key or
function key, restores the default, or switches the shortcut off. Conflicts are
compared by physical key and modifiers, independently of the displayed label.
Dictation keeps its own configurable Fn hold/release behavior. Voice admits one
activity at a time; close the review before starting dictation, Talk or a meeting.
The Nook's Voice menu shows the selected shortcut without a misleading capture
button that would first take focus away from the editor.

Generation uses Apple's on-device Foundation Models API. The selected speech
recognizer and Qwen speaking voice do not affect rewriting. There is no remote
provider, automatic cloud fallback, recording or agent execution. If the local
model is unavailable, the preview remains editable. A twenty-second deadline
ends waiting; cancellation or a stalled model disables further generations until
Voice restarts, preventing a backlog of potentially uncancellable model work.

Only the selected passage (at most 6 KB) goes to the local language model. The
original field value (at most 128 KB), exact UTF-16 range and AX element/window
identity stay in memory for validation. Neither originals nor results enter
dictation history, meeting storage or logs. Closing the review or the five-minute
session expiry drops this state. The explicit Copy result control uses the
clipboard; Replace and Undo do not.

Replacement requires the same readable, editable, nonprotected field, exact
original contents and selection. Voice returns to that editor automatically and
revalidates before writing. It will not replace a whole field or guess a paste
destination for editors that do not expose these Accessibility operations. A
changed or unsupported target keeps a copyable preview. After replacement, Undo
requires the exact resulting contents and caret, then verifies the restored
original selection. A failed write/readback is reported as uncertain and offers
neither another automatic replacement nor a verified Undo.

Automated checks cover state, UTF-16, cancellation, expiry, stale values/ranges,
model failure and uncertain readback. The review window has been inspected in
Light and Dark, and an authored passage was rewritten by the real local model.
Real TextEdit capture from the physical shortcut, exact replacement and immediate
Undo pass, including Unicode surroundings. Early focus refusals remain documented.
Chrome captured text but refused before writing when inactive AX focus changed;
the activation follow-up and VS Code/Electron still need acceptance. Unsupported
editors keep a copyable preview; no clipboard or whole-field replacement fallback
is offered. Known pre-write refusals allow an explicit new Replace click, with
all checks repeated. Model output needs human review for meaning, names, numbers,
negation and commitments. See the host's
`reports/voice-022-acceptance-2026-10-20/README.md` for the installed evidence.
