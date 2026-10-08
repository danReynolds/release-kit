# Native publication fixture

This repository is copied into a disposable Git checkout by RK's native
publication tests. The test supplies a loopback registry, isolated credentials
and empty caches, so no publication reaches a public registry. Run the
qualification suite rather than publishing this example yourself:

```sh
dart test --tags publication --concurrency=1 --reporter=expanded
```

Run from the RK repository root on Linux or macOS with Dart, Git and
Python 3 available. Python's standard library starts owned process groups so a
timeout also terminates orphaned native children. The suite runs automatically
in a separate CI job; `dart test` also includes it locally.

| Unit | Version | Runtime dependencies | Development dependencies |
| --- | --- | --- | --- |
| core | 0.2.0 | none | none |
| format | 0.3.0 | core | none |
| testing | 0.4.0 | core | none |
| app | 0.1.0 | core, format | testing |

The release configuration lists consumers first. Tests must observe provider
publication before runtime consumers while preserving independent versions.
After core and format publish, named app publication succeeds even if testing
is still unpublished. A fresh consumer resolves the app through the registry,
compiles and executes it, and confirms the testing helper is absent from its
runtime package configuration.

The suite exercises stage-only and declined release, named dependency refusal,
successful publication, rejected uploads with interrupted confirmation followed
by fresh-process recovery,
accepted uploads with lost responses, archive propagation lag, immutable-version
conflicts and an API-incompatible consumer control. Successful packages enter
the server only via native Pub HTTP upload. Tests compare uploaded bytes against
the staged archives and verify reuse without repackaging.

The registry implements the native initiate/multipart/finalize protocol and
serves exact accepted archive bytes. Separate controls govern coordinate
metadata, package listings and archive downloads. Request evidence distinguishes
upload attempts from accepted immutable versions. Only negative/background
fixtures may seed preexisting packages directly.

The test entry point imports RK's shared CLI composition and supplies one
validated loopback endpoint for registry reads, publication readiness and native
token matching. Parsing, orchestration, consent, SystemTools and native commands
are shared with the shipped CLI. All Dart commands use the ordinary SDK frontend.
The shipped entry point remains fixed to pub.dev; an ambient PUB_HOSTED_URL
cannot redirect its publication target. A deny-all proxy rejects non-loopback
native HTTP traffic, and synthetic tokens exist only in the fixture.

Permanent native failure controls verify that missing-package solving,
invalid-archive publication and dropped finalization responses exit nonzero.
The dropped-response control also verifies that the archive was committed, so
the RK recovery scenario must reconcile a real failed native command.

This qualifies RK orchestration, native solving, upload/download and recovery.
It does not qualify the shipped wrapper's fixed destination routing, production
pub.dev OAuth/uploader policy, live GitHub Releases, or browser rendering.
Future npm qualification should use its native client and a compatible registry
protocol; share scenario/process support where useful, not dependency-solver
behavior.

An observed existing DX tradeoff: native upload failure enters RK's conservative
ten-minute confirmation window because the version might still have landed.
Consumer availability polling uses the same deadline after a confirmed publish.
The rejection scenario interrupts after an actual rejection and subsequent
absent-coordinate response. The propagation scenario interrupts after an archive
404, proves a named dependent still refuses, then restores availability. Each
resumes in a fresh process. Status 130 is the harness's cancellation result.
These tests do not wait out either wall-clock deadline or qualify the normal
rejection completion report. Existing lower-level tests cover normal failure
reporting with injected native results and waits. Production polling is unchanged.

Tests that run rk share one binary compiled from its sources
(`test/support/compiled_rk.dart`); editing rk during a run makes later test
files compile and run a different rk.
