# NookLocalServiceKit

A small native local-service mechanism for the bounded shared-application P1
codec in the sibling NookPluginSDK. This implementation is independently authored
from public Darwin, Security and libbsm interfaces. No NeroNook private Host H2,
Fuego policy, Inferno addon or other product source is copied or licensed here.
The MIT notice is copied unchanged from NookPluginSDK. No third-party package,
network dependency, listener activation, application entry change or install is
part of this package.

## What the component does

On macOS, `LocalServiceOwner.acquire(policy:)` first checks the actual current
process against exactly one independently supplied self requirement, then holds
a physical per-EUID permanent lock. `LocalServiceListener` publishes the socket
only while retaining that owner. `LocalServiceConnection.connect(policy:)` checks
its real self before connecting and checks the actual connected peer's audit
identity and dynamic code. Listener candidates use the same mandatory proof.

The policy has 1–8 entries in each directional map. Native strings have no JSON
policy API: the total cap is **exactly UTF8(serviceIdentifier) plus the UTF8 bytes
of every key and requirement in both maps, at most 65,536 bytes**. Individual
requirements are 1–4096 bytes without NUL, keys 1–64 ASCII letters/digits/hyphen.
The maps may use the same key on opposite directions. Actual code must match
exactly one configured requirement; zero or ambiguous matches refuse.

A fixed physical `/private/tmp/nero-local-<euid>/` directory is 0700 and owned by
the current EUID. Service names select SHA-256 prefix namespaces; full service
metadata in the regular 0600/nlink1 lock prevents silent digest aliasing. The lock
inode is permanent: it is never unlinked/recreated or stolen. Only an unchanged
socket this listener actually bound may be removed. A preexisting socket,
including an unknown crash remainder, refuses; this package does not guess that
old Voice workers or audio resources are gone. There is no chmod/adoption of an
unsafe existing root/lock. Directory link counts are not stable identity fields;
regular lock files still require nlink1. Original native self and peer failures
are permanent for that owner/proof. Peer EUID and audit session must equal the
captured actual self, and later checks compare original whole audit tokens,
dynamic native code and retained connected descriptor observations.

`receive()` returns one validated P1 envelope or clean EOF. The read pump keeps
at most one decoded frame and bounded raw bytes, decoding one LF line at a time.
A private delivery receipt pauses the original reader through the public call's
post-await revalidation. Thus a terminal data frame cannot be discarded just
because the pump raced ahead to EOF; there is no clean-EOF native-proof bypass.
Explicit Stop or identity failure still refuses data. Bounded raw reads may discover
actual zero-byte EOF before a fresh token lookup; empty-framing EOF is cached nil,
not a permission, detached acknowledgement or resource-retirement receipt. Every
nonnil frame still requires strict native proof before decode/publication and
again after the public await. No buffered-data or captured-token authority
fallback is allowed after a peer closes.

`send()` validates/encodes real P1 and retains the whole bounded FIFO, including
its active partial write. Observer cancellation cannot silently delete or retry
admitted sequenced bytes. Receive/accept cancellation removes only that exact
observer. There is one outstanding receive/delivery and one outstanding accept;
concurrent calls refuse. Accepted and pre-authentication leases count toward the
four-connection limit until their own real IO cleanup. Listener Stop preserves
already admitted connections. Every socket uses per-FD SO_NOSIGPIPE; no global
signal disposition is changed.

## Graceful finish and abort

`finishSending()` synchronously seals new send admission in its executing body
before its first await, using the same lock as enqueue. It keeps all already
admitted whole lines, including the active write and cancelled observers, in the
same original FIFO. The one original writer drains them, then performs one
actual SHUT_WR while retaining native-call/FD custody. A pre-created bounded
finish-result observer is shared by all finish callers and joined by original IO
cleanup. A caller cancelled after admission still waits for that original result,
then receives CancellationError; it cannot cancel physical finish or reopen the
queue. A cancellation detected before admission creates no new finish request.
Repeated admitted finish calls observe the same historical result, not fresh
native permission.

Success receipts only completed local FIFO writes plus the actual successful
write-half-close return. It does not certify a remote read, application approval
or scoped service retirement, and does not ask for a new peer grant after FIN.
Ordinary sends retain their strict original checks; the caller **must await all
terminal ordinary-send calls before invoking graceful finish**. The physical FIFO
also retains cancelled observers, but a cancelled or late observer can still get
a conservative outcome; finish never manufactures a remote acknowledgement. The FD, proof and original read owner stay
held until actual terminal EOF or scoped Stop. Current receive-EOF behavior is
whole-connection retirement, not a promise of a general-purpose half-duplex
socket API after EOF.

The P1 terminal responder awaits its retired/detached sends and finishSending,
then stays connected while the receiver gets and revalidates that final frame,
observes actual EOF and closes. The sender can then observe only a local EOF.
A peer that fully closes before its frame can be revalidated may be refused:
StopIO is immediate abort, not graceful finish. No acknowledgement or successful
resource cleanup is invented from unknown terminal IO. Existing higher-layer
deadlines apply; there is no timed FD release or automatic resend.

Explicit Stop before finish completes conservatively aborts it. Genuine read EOF
after the original SHUT_WR has begun instead joins that actual return and can
preserve its successful local receipt. Earlier real failures stay latched; EOF
cannot rehabilitate them. A real active public Peer.revalidate failure is retained
through successful native close and later EOF. Intentional Stop that already won
invalidation, or a stale retired-peer query, does not retrospectively poison a
clean original completion. Immediately after the actual SHUT_WR return, finish
reads only an already recorded native failure, without revalidating for a fresh
peer grant. That negative snapshot is its local receipt decision point. Later
faults remain in retirement and never rewrite an earlier historical finish.

## Ownership and completion

Read, write and accept loops use dedicated DispatchQueues with bounded
nonblocking POSIX calls and poll, not blocked Swift cooperative workers. Each
original cleanup owner is created before its loops, joins their actual return,
the exact Stop shutdown call, original finish-result observer, outstanding
delivery and in-flight native proof checks, then closes original descriptors once. A stop request never closes a
potentially recycled FD. The accepted owner and capacity lease remain held until
that actual close. All continuation delivery is outside locks. Public wrapper
deinitialization requests its scoped Stop; it never quits a separate service.

The only unchecked implementation primitive is `LockedState<State>`. Its lock
protects: identity validity/native references/in-flight native calls and drain
continuations; owner invalidity; connection stop/failure/FD/buffer/delivery and
receive/write reservations/queue bytes/sealed finish/result/native-start/abort
state; listener stop/failure/FD/observer/buffer
and capacity leases. Native Security/syscalls, semaphore waits, awaits and
continuation callbacks run outside the lock. Native identity references are
private, never Codable constructors or role assertions. Original proof FD close
waits in-flight Security calls; accepted owner validation is inside that same
custody and the owner is released after original socket close.

`retirement()` observes the same pre-created original local cleanup. Its waiter
cannot cancel that cleanup. `closed` means the owned local native calls, loops,
callbacks and descriptor cleanup returned without a latched failure; errors
remain `failed` with a reason. This **does not prove remote jobs, Voice audio,
models, shared app approval, provider authority or durable clean-resource state
have retired**. Caller P1 state machines still enforce direction, current session,
sequence, hello/approval/heartbeat deadlines, role/capability policy and exact
run/Stop/detached/retired joins. Native eligibility never confers an application
grant. An unknown or unclean Voice resource ledger must stay closed outside this
kit even when its process lock is free.

## Source and qualification limits

The first cohort adds only this independent package. Existing manifests,
application/new-instance launch modes, profiles, grants, accounts and installed
apps stay unchanged. Future actual Voice/Nook/Electron-main attachment, resource
ledger and Developer ID composition are separate mandatory work. Mac14 is the
declared source floor; actual qualification uses macOS27.0.1 with SDK27.0; Mac26 runtime remains unverified. Non-Mac methods
explicitly refuse unsupportedPlatform; this is not Linux/Windows runtime support.

The authored tests use real private files, flock, sockets, original queues and
Security calls. Positive native mechanics explicitly derives the **actual
current test host's designated requirement** and checks it, then uses that exact
requirement in an isolated policy. There is no fake Peer, skip, JSON override,
unsigned success fallback or operational grant. Same-process listener/client and
socketpair evidence is not two different native processes or Developer ID app
acceptance. Raw-engine socketpair tests exercise the same actual pump and write
implementation without pretending to authenticate a principal. Internal
read-only queue/observer facts and an optional unique local send-observer ticket
exist for causal transport tests; they are not P1/native IDs or permissions.
Each native-positive test fails honestly if its actual test-host identity cannot
be proved. No model, audio device, capture, account, GUI or explicit signing is
used. Source authoring alone claims no compile/test/runtime pass.

## Candidate010 evidence status

The original007/collector008 suite is preserved exactly: 23 actual methods,
22 passed and one failed, zero skipped. The failing immediate-full-close terminal
case exposed the kernel's loss of live peer-token lookup after peer FD close,
even with queued bytes still readable. This candidate implements the separately
reviewed graceful-half-close direction rather than accepting unproved bytes.
Root's separate raw half-close006 probe observed four bytes then actual EOF with
the token still available while the sender FD remained held; that is not this
public method's qualification. Candidate010 source/tests have not been run by
the author. First-public-method/native-process qualification and all operational
app/service gates require their own original results.
