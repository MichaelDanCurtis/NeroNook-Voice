# Voice connection and meeting review · November 5, 2026

This follow-up depends on the shared Voice implementation in draft PR #5. It changes one meeting-notes rule and test coverage; no SDK, protocol, permission or installed build is changed.

## Meeting notes

Negated cancellation phrases (for example, “Don't cancel the launch checklist” or “We haven't cancelled the launch checklist”) preserve the existing commitment, owner and deadline. Explicit cancellation still cancels the task and retains its transcript citations. Matching remains conservative, English-first and sentence-scoped; this is not a general natural-language negation parser. Multilingual and mixed-clause statements still require review.

The unchanged production implementation reproduced six incorrect cancellations before the repair. New tests cover straight/curly apostrophes, past-tense denial, never, passive wording, positive cancellation, and negation in a separate sentence.

## Connection coverage

A new isolated test makes six real signed-self native socket connections to the production Voice listener, checks hello/session/nonce, detaches, observes detached and EOF, joins original client/context retirement and reconnects. No native consent or speech is requested. Six sequential connections exceed the four concurrent-client limit and detect unreleased admission slots.

The held enrollment-prompt fixture now keeps its response continuation pending after task cancellation, matching a native callback's required lifetime. An AsyncStream consumer previously ended on cancellation, making the test's shutdown-wait assertion timing-dependent. Production shutdown behavior is unchanged.

## Verified and still open

- Fresh ordinary Voice build: 207 selected setup/context/meeting tests pass, zero failures or skips.
- Confined native Nook with normal signing identity and an existing signed Voice service: module installation, service selection, session approval to Running, Disable, re-enable/session approval to Running, and the real Meetings web surface observed.
- Voice's process and lifecycle epoch remained unchanged across detachment/reconnection. The private host quit normally and the usual Nook was reopened. No recording or Talk was started by this walkthrough.
- Native checks used the retained Voice146 service and a freshly built current host. They do not establish installed acceptance of this meeting-notes repair, a new full Voice package, or resource cleanup under an active speech workload.
- Real room/Teams recognition accuracy, speaker-error rate, overlap quality, long-session behavior and other-platform coverage remain open. No new acoustic-quality improvement is claimed from source tests.

All builds and installation checks remained local. Opening this source PR is not a public binary release; the release floor remains 0.35.0.
