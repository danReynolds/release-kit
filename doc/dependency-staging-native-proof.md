# Native dependency staging proof

Measured 2026-10-02 on macOS arm64. This qualifies a native mechanism, not the
repository staging implementation. RK production paths are unchanged in this
slice. All registry activity used disposable loopback fixtures; no uploads,
tags, drafts or publication credentials were used.

## Decision

Use hosted metadata discovery, then native cache replay with original manifests
and exact archives. Keep discovery payloads separate from release artifacts.

`test/native_hosted_staging_test.dart` has nine native cases. The first stages
core 0.2.0 with Pub, discovers the consumer 0.1.0 solution using shadow metadata,
preloads exact original archives into a fresh cache under original source URLs,
resolves the original consumer offline, packages it normally and runs a compiled
consumer. The consumer prints `42`; its published manifest remains byte-for-byte
unchanged and its entire lockfile is unchanged after native packaging.

The discovery view restricts a selected source/name to its chosen local version.
With core accepting `>=0.1.0 <0.3.0`, bridge accepting `>=1.0.0 <3.0.0`, selected
core 0.2.0 and bridge 2.0.0 requiring core ^0.1.0, Pub backtracks to bridge 1.0.0,
which accepts core ^0.2.0. It does not silently select public core 0.1.0.

The remaining native cases prove:

- A fixed incompatible bridge fails native solving.
- A hosted bridge exposes a staged-core edge absent from the consumer manifest.
- An explicit other-registry core resolves that registry's value `99`; a graph
  requiring the same name from two different sources fails.
- Excluding a provider library from its native archive produces analyzer
  findings during native consumer packaging and causes real compilation to fail.
  Pub writes an archive despite those potential issues, so warning reporting
  remains necessary; success alone is not a clean-validation claim.
- Provider development dependencies are ignored when consuming its archive.
- An unpublished dev-only helper with a back-edge to the consumer still works.
  A separate external root ignores that helper and published workspace metadata,
  fails while the runtime provider is unavailable and succeeds when it is hosted.
- Original-archive replay rejects a dependency concealed by discovery metadata.
  A second case preloads that dependency for another root requirement: native
  replay then succeeds, but full graph comparison exposes the undiscovered edge.
  Matching coordinate sets alone is insufficient.

The fixture helper owns its Git roots, local servers, caches and child processes.
Discovery uses manifest-only archives and `--no-example --no-precompile`.
Runtime validation uses a separate cache populated by native `pub cache preload`.
No discovery cache path reaches compilation. Production must compare actual
archive manifests with discovery metadata before replay; the native refusal is
additional protection, not a replacement for that comparison.

## SDK matrix

| SDK | Pinned Pub revision | Selected mechanism |
| --- | --- | --- |
| 3.10.4, RK minimum | `f7f1891e2de3d795532f45ec214f88ac912ffcd6` | Nine native cases passed |
| 3.12.2, RK formatting/analysis CI | `74408212b5348003381bc63f3b59274aaa23cfa3` | Nine native cases passed; seven alternative-mechanism probes passed |
| 3.13.5, stable channel checked 2026-10-02 | `ec276d10a7fa0f6c6ec005340fb9ad29f3b012d0` | Nine native cases passed |

SDK revisions come from each tagged SDK's `DEPS`. For 3.12.2 see the pinned
[Pub publication implementation](https://github.com/dart-lang/pub/blob/74408212b5348003381bc63f3b59274aaa23cfa3/lib/src/command/lish.dart)
and [native hosted archive preload](https://github.com/dart-lang/pub/blob/74408212b5348003381bc63f3b59274aaa23cfa3/lib/src/source/hosted.dart).
`--from-archive` implies skipped validation, so public consumer resolution is
still an explicit future preupload gate. `pub get --dry-run` downloads packages;
it is not a metadata-only primitive. Discovery therefore serves clearly marked
manifest-only payloads that cannot be adopted as runtime artifacts.

Reproduce the native tests with the normal RK test SDK:

```sh
dart test test/native_dependency_staging_test.dart test/native_hosted_staging_test.dart
```

To select a different native SDK while retaining the normal test runner:

```sh
RK_NATIVE_DART=/absolute/path/to/dart dart test test/native_hosted_staging_test.dart
```

`RK_NATIVE_PROOF_REPORT=/absolute/path/report.json` records hashes and SDK output
for the full backtracking/packaging/compile case. The measured 3.12.2 run recorded:

| Evidence | SHA-256 |
| --- | --- |
| Provider native archive | `a923ab0e2b4ee4fae99b12364aeca8c96039182541d6d587c308ca5b9095bb03` |
| Provider original manifest | `e459f0974126479eca972049f12526cdc762efe0a5f3cac1834b2951def242dc` |
| Consumer native archive | `98efa6dddb6afbd3404e0527b316cfa9b912c3ed8850cb45ff4f0b4350215e65` |
| Consumer original manifest | `c07caed047b18cb435c06b170ab98bfb91f942ea492e31b601fd3c8c1e79ba8b` |

Archive hashes are evidence from one run, not a cross-SDK byte-stability promise.
The replay lockfile's provider hash is asserted equal to the input archive hash.

## Rejected alternatives and remaining implementation work

`test/native_dependency_staging_test.dart` retains the workspace investigation.
A native workspace preserves version constraints and backtracking, but shadows
same-name dependencies from another explicit registry and rejects a valid ^3.0.0
SDK lower bound. Those are successful demonstrations of why RK must not use it
as the runtime artifact binding mechanism. Managed path overrides likewise do
not establish a constraint-preserving native solution by themselves.

This slice proves ordinary package preparation and a workspace-marked consumer's
external runtime check. It does not prove repository scheduling, same-unit
producer receipts, cross-unit imports, safe production extraction, frozen-stage
reuse or public archive provenance. Those remain the following implementation
slices. Same-unit handoff can use the same native archive primitive without a
completed unit receipt; its scheduling/receipt invariant still needs integration
tests. The fixtures use an owned archive reader, not a production extractor.

Production discovery must select only compatible reachable candidates, preserve
named-scope hosted fallback, and avoid introducing unrelated candidates into the
solve. Freeze candidate/source and metadata facts before scheduling; prove exact
archive-manifest agreement and identical native replay afterward. A graph that
changes during preparation must invalidate discovery, never silently gain edges.

## Evidence review

Both independent reviewers approved proceeding to slice 2 after inspecting the
native proof. Architecture review required full graph comparison and scoped
candidate selection; native review additionally required checking the original
dev-helper version and back-edge constraints before any managed helper override.
Production integration must retain those assertions. The ninth regression passed
on all three SDKs after review.
