# ASR dependency audit

The package app requires macOS 26.0, while the separate MLX worker is built for
macOS 14. A missing on-disk Swift dylib is not evidence of a missing OS provider:
macOS can provide it from the dyld shared cache. On the inspected Mac 27.0.1,
`_dyld_shared_cache_contains_path` confirms
`/usr/lib/swift/libswiftCompatibilitySpan.dylib` without loading it. The retained
worker lists `/usr/lib/swift` before its developer rpaths. No supported-Mac loader
failure has been demonstrated, and this change does not embed another runtime.

Before `package_runtime` or any staged signing, packaging reads the stripped
worker's load commands using Apple's `otool`. It refuses unsupported non-system
loads and developer-only or shadowable Swift rpath dependencies. Swift rpath
acceptance requires an actual current-OS shared-cache provider through a system
rpath encountered before any non-system rpath. Required absolute system install
names also require current shared-cache presence. The full transitive closure is
not independently loaded or audited. Weak missing dependencies are explicitly optional. Unrecognized
layouts fail closed; this is intentionally not a general Mach-O resolver.

`Contents/Resources/ASRDependencyAudit.json` records the exact pre-sign worker
hash, metadata hash, ordered system rpaths (other paths redacted), deployment target and current-OS evidence.
Signing subsequently changes the worker bytes. The report explicitly says
`minimumOSCompatibilityVerified: false`. It does not establish macOS 26 loader
compatibility, another architecture, actual ASR, GPU/model readiness, or an app
launch. A real clean macOS 26 test remains required. Thin 64-bit little-endian
Mach-O executables only are currently supported. Identity checks detect observed
changes across reads; they do not promise exclusion of a malicious same-user race.

The official `swift-stdlib-tool --print` selects CompatibilitySpan for this
worker's older deployment target, even on a host that supplies it in the cache.
That selection alone is not a reason to copy Xcode libraries. If supported-OS
testing later proves a missing provider, separately review runtime collection,
source/toolchain provenance, recursive dependencies, app placement and signing
before embedding. Swift's published source license is Apache 2.0 with a Runtime
Library Exception; this report does not infer permission for arbitrary Xcode
binary redistribution from that source license.

Primary references:

- [Upstream Swift issue, macOS 26 rpath fix and macOS 15 distinction](https://github.com/swiftlang/swift-subprocess/issues/189)
- [Swift license and Runtime Library Exception](https://www.swift.org/legal/license.html)
- [Apple Xcode and Apple SDKs Agreement](https://www.apple.com/legal/sla/docs/xcode.pdf)

Fixture tests exercise parser/policy and authored file data. They never execute
the worker, load a model, open audio, copy dylibs or sign code. This report-only
candidate has not been adopted into the normal package script.
