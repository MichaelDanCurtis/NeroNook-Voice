# Hold to dictate · Voice 0.17 / host 0.32

Place the cursor in another app, hold **Fn**, speak after **REC** appears, then
release. Voice stops microphone capture, finishes the selected local recognizer,
applies the selected Clean/Formal/Literal style and pastes into the app/window
where the hold started. It never presses Send. If focus changes or paste fails,
the words stay in Voice. Standard secure password fields are refused.

On the main Voice card, **Shortcut** offers Fn, Option–Command or Custom.
Custom opens Voice settings: choose **Record…**, press/release modifiers or a
key combination, and it is saved. Modifier-only holds, modified keys and bare
F-keys are supported; unmodified typing letters are excluded. Existing saved
shortcuts are preserved during upgrades. Off disables registration. Hold to talk
is the default; the existing press-to-toggle choice remains available.

**Live words** on that same card chooses **In the Nook** or **Bottom captions**.
The Nook opens a little, shows a red REC indicator and small input meter, and
its outline responds subtly to actual microphone level. The words remain still.
Reduce Motion disables the shaking. The cue changes to PROCESSING on release,
then shows completion or a retained-draft error before dismissing. Caption panels
do not take editor focus. The target window's display is used when available.

Apple Speech and Nemotron provide live words. Parakeet currently transcribes
after release; its recording indicator and input meter still work. Apple Speech
is the default for new setups; the current owner's selected model is preserved.
MLX capture begins before the streaming model finishes loading, so startup audio
is buffered locally instead of discarded. Releasing before microphone readiness
cancels that attempt and never starts recording afterward.

Fn/modifier shortcuts and insertion use Voice's existing macOS Accessibility
permission. If macOS still opens Emoji/system Dictation for Fn on a particular
keyboard, set Keyboard → Press Fn/Globe key to → Do Nothing, or pick another
shortcut. Device/OS handling of Fn can differ: a bare Fn that the keyboard never
sends cannot be captured by the app. No system keyboard preference is changed
by this feature.

A brief modifier tap is ignored. Fn+arrows and typing while held cancel the
attempt rather than pasting accidental text. Changing shortcuts is disabled
during recording/processing. Audio remains on this Mac; the short dictation
buffer is bounded to approximately one minute and is not saved as a recording.
Meeting recordings remain an independent explicit workflow.

This work is independently authored. OmniVoice remains a behavior reference;
no new code or assets were copied from it. Existing dictation cleanup and snippet
provenance are unchanged. Public distribution stays held until host 0.35.0.
