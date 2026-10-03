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

## Production primitives and real Fleury preparation

The production archive reader, hosted discovery and original-registry archive
replay now replace the fixture implementation for preparation tests. Guarded
native extraction, full manifest comparison, frozen external bytes and generic
context/slot contracts have separate regression coverage. These are implemented
primitives; command orchestration and frozen receipt authorization still require
integration.

On 2026-10-02, an owned source snapshot of Fleury commit
`14d76107b6ba468b44e75c120390eddca271b307` was prepared using Dart 3.12.2 and these
production primitives. All four manifests resolved 55 hosted dependencies.
MCP, test and web consumed the exact newly prepared Fleury archive through
native offline replay. Each unchanged manifest was packed with
`pub publish --to-archive`; no publication or tag was attempted.

| Package | Version | Native archive SHA-256 |
| --- | --- | --- |
| fleury | 0.1.0 | `c22d8614ee6c3e05ed2ceed3d68a18b7aa281e6ec8ff4e4b01dd9df3d6b032e2` |
| fleury_mcp | 0.1.0 | `5b4d806f07cd3dd90b19ae98ec2040c8adbf130c64adc05ea135ad7d758b372d` |
| fleury_test | 0.1.0 | `4281af913262212d96d85557a5bc8439659220baffb472a077f61afb681125c4` |
| fleury_web | 0.1.0 | `1cd080cbef95e6e083172946ac1d8ae3ceb797def370b49edf0daba34af38119` |

MCP and web retain Pub's warning about their exact `fleury: 0.1.0` constraint.
The test does not silently broaden it or label those archives warning-free.
It proves native artifact preparation, not yet bare `rk stage`, stage recovery,
public dependency gates or application smoke-test qualification.

Real registry metadata exposed two compatibility requirements now covered by
regressions: implicit hosted dependencies in old SDK manifests need Pub's legacy
long hosted syntax in the discovery view, while explicitly written shorthand
must retain its native SDK gate; unused historical versions with unsupported
sources must not veto a valid native selection. Selected unsupported sources
still refuse. External archive downloads bind the native digest and complete
manifest, limit transferred bytes and lifetime, and redact signed fetch URLs
from transport/redirect diagnostics and portable evidence.

## Bare Fleury command qualification

On 2026-10-03, the production `rk stage --json` command prepared current Fleury
main `882c6642bbc2468f6f2bd9241e4e66a61fe99fe9` in the reused, clean review worktree,
using Dart 3.13.5. All four units completed with exit 0 and no problems. Every
public action remained `not_attempted`; no release authorization or publication
session was requested. MCP and web retained the exact-dependency Pub warnings.
The source worktree remained clean.

The first run refused an existing schema-12 stage, as designed. Its unpublished
stage store was preserved separately before the fresh command run. No old receipt
was upgraded or treated as proof of the new behavior.

| Package | Version | Native archive SHA-256 |
| --- | --- | --- |
| fleury | 0.1.0 | `0699e8a5576672e53de44caffaf7b5320f62f1336250df757f32f89dd83473d7` |
| fleury_mcp | 0.1.0 | `d9810e1361a7e57f14e5484e6294376f165d8c938d2307d5c0f68025d34ddee2` |
| fleury_test | 0.1.0 | `2820d5b4ebd18f200884e5b024b0fc6e8ca528cb8128adcf62e8358d66d11c5c` |
| fleury_web | 0.1.0 | `b2b8d7e7c762ee4e6cff4b7ab97fe71007940afc59296fa24353992ab075d14f` |

These hashes are from the final packet-3 rerun after status, retry and command
fixes settled. Each consumer's copied core archive was hashed from disk and
matched the core producer's exact `0699e8...73d7` archive; copied proof files also
matched their recorded size and digest.

A fresh `rk status --json` recognized the four actual bound stage IDs, beginning
`e0593a455421`, `dee3aeb2ae63`, `9a836788e44d` and `95bdb3734185`, respectively.
Each stage was locally exact with native authorization explicitly deferred. The
status command preserved all 22,418 entries in the local stage store byte for
byte, with modes and mtimes unchanged. Its public observations still correctly
reported that Fleury must become public before its dependents publish.

The qualification retained full command reports and independently hashed proof
inventories. It exercised no actual upload, remote tag, GitHub release or tap
write. This qualifies whole-stack private preparation and read-only status;
repository release preparation, aggregate consent and public dependency gates
remain separate required qualification.
