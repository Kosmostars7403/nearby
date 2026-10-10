# iOS Hotspot consent and cancellation regression

Run on a Mac with Xcode and Python 3; no device, signing, radio access, Bazel,
OCMock, package downloads, or app launch is needed:

```sh
python3 internal/platform/implementation/apple/Mediums/Hotspot/Tests/JoinRegression/run_tests.py
```

This XCTest harness compiles the production iOS join methods, gate helpers,
constants, disconnect and SSID lookup methods verbatim from `GNCHotspotMedium.m`. It replaces
only the NetworkExtension/CoreLocation API boundaries and monotonic clock.
Generated source and SHA256 provenance are written to a temporary directory;
`--output-dir /path` retains them at a chosen location. It does not modify SDK
source. Unique fake Objective-C class names prevent a real framework loaded by
XCTest from handling a fake call.

The consent regression holds the actual OS completion for **20 seconds of wall
time**, exceeding the former 18-second deadline. The full suite takes roughly 21
seconds. It also checks pre-cancellation, prompt cancellation while apply or
SSID fetch is pending, concurrent joins from separate medium instances, cleanup
before reconnect after a late callback, the 90-second deadline, a fresh deadline
for the next apply, user denial, already-associated success, wrong-network
verification, and the legacy selector. The deadline test advances a fake
monotonic clock; the production timeout constant is never shortened.

Reproduce the historical failure against the parent revision (expected nonzero
exit and assertions for premature return/removal and failed join):

```sh
python3 internal/platform/implementation/apple/Mediums/Hotspot/Tests/JoinRegression/run_tests.py \
  --revision 8406af2a2dcc8eed0399e6ce1bafcb65dec42e44 \
  --test testConsentCanTakeLongerThan18Seconds
python3 internal/platform/implementation/apple/Mediums/Hotspot/Tests/JoinRegression/run_tests.py \
  --revision 8406af2a2dcc8eed0399e6ce1bafcb65dec42e44 \
  --test testCancellationReturnsPromptlyWithoutAbandoningOSOwnership
```

The baseline lacks the cancellation selector. Only the test caller adapts to
its legacy selector; extracted production source is unchanged.

These tests validate SDK ownership, deadlines and cancellation against held OS
callbacks. They do not simulate iOS consent UI, establish why an OS request
returns an NSError, or prove successful association on physical devices. Full
iOS compilation and paired hardware verification remain separate checks.

## Scoped cancellation tests

The Hotspot bandwidth-upgrade call takes an operation-scoped cancellation flag.
An endpoint reset can therefore prepare a new connection without clearing an
older operation's cancellation. The 6 standalone C++ tests include an already
cancelled parent, cancel/reset between polls, independent retry, disabled
cancellation, parent lifetime, and 1000 concurrent scope-destruction/cancel races.

With a configured Bazel workspace:

```sh
bazel test //internal/platform:cancellation_scope_test
```

Or use CMake with local Abseil and GoogleTest source trees (no WebRTC needed):

```sh
cmake -S internal/platform/implementation/apple/Mediums/Hotspot/Tests/JoinRegression \
  -B /tmp/nearby-cancellation-tests \
  -DABSEIL_SOURCE_DIR=/path/to/abseil \
  -DGOOGLETEST_SOURCE_DIR=/path/to/googletest
cmake --build /tmp/nearby-cancellation-tests --target scope_tests -j4
ctest --test-dir /tmp/nearby-cancellation-tests --output-on-failure
```

## Validation evidence (2026-10-10)

- Actual Objective-C source: 11/11 XCTest PASS in 20.7 seconds. The baseline revision
  above fails the 20-second consent test and prompt-cancellation test as expected.
- Actual `cancellation_flag.cc`: 6/6 C++ tests PASS. Three cancel/reset regressions
  fail when their operation reuses the parent flag, matching the former caller.
- Production Objective-C syntax checks pass for iOS arm64 and macOS; the Hotspot
  C++ wrappers, bandwidth-upgrade handler and Apple Objective-C++ adapter compile.
- The full medium C++ suite was not run: this environment lacks Bazel and its
  WebRTC headers. ASan could not run because its runtime hung before `main`;
  ordinary tests passed, so no sanitizer result is claimed.
- Physical-device verification of this patch is a separate step.

## One prompt per explicit run (2026-10-10)

Applications may opt in with `ConnectionManager.beginWifiHotspotSession`, and
must call `endWifiHotspotSession` before closing that run. This allows one OS
apply per explicit run. BWU socket retries can reuse its successfully joined
SSID without another apply. An ended run blocks delayed work between runs; a
new explicit run gets a new allowance, while any pending old OS operation still
owns the process-wide gate until its completion/cleanup. No credentials are
included in the callback or logs.

Only the exact NetworkExtension `userDenied` domain/code calls the handler, once
on the main queue. It does not disconnect BLE: the application owns presentation
and orderly transport termination. Other failures, association verification and
timeouts are not mislabeled as refusal. Both the OS callback and queued event
retain/check their run ownership, so an old callback cannot reject a later run.

The actual-source suite now additionally tests a refusal followed by automatic
BWU retry, one refusal event, a fresh explicit run, pending and already-queued
stale callbacks, other error domains/codes, association verification, reuse
without a second prompt, invalidation after disconnect, and a late refusal after the consent deadline.

The historical re-prompt is reproducible against the previous pin:

```sh
python3 internal/platform/implementation/apple/Mediums/Hotspot/Tests/JoinRegression/run_tests.py \
  --revision 0859eeaed77d8ad9a7c82d3b5c945dc53b27d0bc \
  --test testUserDeniedPreventsAutonomousSecondApply
```

That baseline issues two applies instead of one (expected RED). The test caller
omits the not-yet-existing explicit-run API for old revisions; production join
source is still extracted verbatim. Full Swift/iOS application integration and
physical refusal/retry checks remain separate from this radio-free harness.

Current validation: 20 actual-source XCTest cases (including the 20-second
consent hold), Objective-C iOS/macOS syntax compilation, and all 13 production
NearbyConnections Swift sources typechecked against the updated Objective-C
public headers. Full application linking/hardware checks are still separate.
