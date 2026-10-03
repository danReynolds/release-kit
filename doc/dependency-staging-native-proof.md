# Native dependency staging proof

The initial mechanism was measured 2026-10-02 on macOS arm64, before production
integration. Later sections record production primitives and command qualification;
the final section records completed full-suite and Fleury qualification on
2026-10-03. Registry fixtures use disposable loopback services and local Git
remotes. No public package upload, public repository tag, GitHub release/draft,
or tap write occurred.

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
an explicit preupload gate, implemented in packet 4 and qualified separately below. `pub get --dry-run` downloads packages;
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

## Rejected alternatives and initial implementation boundary

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
context/slot contracts have separate regression coverage. At this review boundary,
command orchestration and frozen receipt authorization still required integration;
the later command section records that work.

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
require the separate packet-4 qualification below.

## Packet 4 public boundary fixtures

Dart publication now projects original runtime constraints through frozen selected
manifests. Development-only providers and private helpers impose no public edge;
a dev requirement shadowing a runtime name does not lend that selection's
transitive dependencies to runtime. Public checks preserve the staged bindings.

Each pre-act check fetches exact selected first-party archives from their original
registries and validates digest and manifest. A fresh public environment preloads
only the prospective consumer archive, using its original hosted identity and a
consumer-only synthetic lock. Native Pub resolves every runtime dependency from
public sources. Post-solve checks bind the consumer's source, version, digest,
package location and full extracted inventory; a publicly available replacement
under the same version cannot stand in for the proposed archive. Relevant public
provider bytes are checked again after solving. A broad compatible range may
select a newer public version, recorded only as transient invocation evidence.

The fixtures cover absent/changed provider archives, same-version consumer
replacement, public resolution failure, development helper/workspace exclusion
and broad-range selection. The final native run passed 52 affected archive,
public-boundary, projection, discovery and helper cases on Dart 3.13.5. The 25 new standalone cases and three composed real-package
cases pass on both stable 3.13.5 and minimum 3.10.4, including racing-provider
checks. An SDK-only case proves that standalone Dart attempts the public native
solve and reports the unavailable Flutter SDK; projection never bypasses it.
These subsets do not qualify the complete repository release command.

Current limitation: an SDK runtime branch that reaches a staged first-party
provider refuses as unsupported. The frozen SDK graph lacks the original hosted
constraints needed to prove the exact-public obligation. A branch containing only
public dependencies remains in native consumer resolution. This distinguishes
unsupported proof from a native unsatisfiable graph; runtime path/Git substitutions
also remain unsupported.

The blocking gate runs before the target's attempted/acted boundary and returns
`RK-PUB-018` on native public-proof failure. The coordinator then rechecks the
stage, context and destination and uploads the unchanged archive. Thirty-one
focused coordinator cases pass on stable, including consent drift, exact public
recovery binding, local-only output preservation and global no-op guards. These
are local fixture results, not live-registry publication or the final full-suite/
release qualification recorded below.

Mixed-unit qualification also distinguishes provider eligibility from output
reproduction. An already-public package is a hosted dependency input, but the
current complete-unit contract still packages every configured output. Native
tar entry mtimes can change raw archive bytes despite identical file contents;
release correctly refuses that immutable mismatch before consent. Preserve or
restore the original matching stage, or, for a fresh tagless setup where the
public package never had an RK stage, regroup it into its own fully-public unit
and prepare the remaining members separately. Regrouping does not bypass an
existing frozen-stage or tagged-unit recovery requirement. A tagless mixed package-only unit may attempt fresh
preparation on either verb; built-asset progress or an exact configured unit tag
still makes a missing original stage recovery-critical.

## Final qualification — 2026-10-03

Implementation commit `f5b2c46` completes packet 4. Qualification-only documentation
and CI-formatter cleanup follow it without changing the RK implementation digest.
Both independent reviewers approved the production boundaries after iterating on
recovery consent, local-only scope guards and mixed-package unit progress.

- Full `dart test`: **1,885 passed, one opt-in Homebrew installation test skipped**
  on each of Dart **3.13.5** and CI SDK **3.12.2**, on macOS arm64. These are two
  executions of the same suite, not additive coverage. CI's disposable macOS
  runner separately enables its real Homebrew installation check.
- Pinned 3.12.2 formatting, whole-repository analysis, diagnostic-index validation
  and `git diff --check` pass.
- Minimum 3.10.4 native archive/replay and public-consumer checks pass, including
  the final four tagged/mixed recovery cases. The independently reproduced
  minimum-SDK macOS AOT-bundle limitation remains outside this qualification;
  archive and direct-executable support are qualified.
- Native command fixtures prove all private work precedes one confirmation and
  publication sessions; later preparation failure produces no public action;
  four independent package versions publish in native runtime order to a local
  fixture; named scope never expands; exact saved partial stages resume without
  discovery or repackaging; public-proof failure remains not attempted.

Actual Fleury source is `882c6642bbc2468f6f2bd9241e4e66a61fe99fe9`, verified against
remote main on 2026-10-03. RK upstream remains
`6e7bb165c8027d8fc5e5293b45432850cf3229f8`. The final source-run RK digest is
`39f74aeae4ef9efcdc79f3ade4ab7763929e8fb068fd1b22ff9d47d27b84c5a5`, stage schema 13,
using Dart 3.13.5 on macOS arm64. The isolated Fleury checkout and its release
configuration remain unchanged.

The actual `rk release --json` with closed stdin and no `--yes` completed all four
private stages, then stopped only at `RK-AUTH-001`. Every public action remained
`not_attempted`. The MCP/web exact-version Pub warnings remained visible.
Subsequent bare `rk stage`, named `rk stage fleury_mcp`, and named staging after
reversible removal of the core provider stage all succeeded with the same saved
identities, bytes, modes and mtimes. The provider was not rebuilt and was restored
after the check. `rk status --json` preserved **44,832** stage-store entries and
explicitly deferred native/public readiness authorization.

Each consumer's imported core archive and copied proof were independently hashed
and checked for their recorded size/mode. The imports match the exact core
archive below. Every archive retains its source `pubspec.yaml` byte for byte and
contains no workspace override file.

| Package | Version | Final native archive SHA-256 |
| --- | --- | --- |
| fleury | 0.1.0 | `decfa39bc785b03232b5f0b32f6aed95f5b00acdbd4fc61d7e190dfb6e791253` |
| fleury_mcp | 0.1.0 | `a82e328a82f382f2792e9e66399b2b78a4fafdd8c1c26969b759011ee06eb915` |
| fleury_test | 0.1.0 | `bbaa07e97a322975c0c8b733dabd3f8bc1f3ff4323e9638a1ab2fb416869b8b9` |
| fleury_web | 0.1.0 | `ad6947d40d216f07f663089635abcf5318e61af113589d9a7e01213031080982` |

The exact extracted archives then supplied an isolated consumer. The staged
Fleury CLI generated an application with `fleury create --no-pub`; app-local
overrides selected the extracted archives without altering their manifests.
Dependency resolution, analysis, both generated widget tests, native application
compilation, MCP executable compilation and browser JavaScript compilation all
passed. The compiled MCP server launched the compiled generated app, read its
semantic tree, activated Increment and observed Count changing from 0 to 1.
This is native/MCP interaction and web compilation evidence, not browser rendering
or real registry-publication qualification.

Reproducible fixtures are committed in the native stage, publication, consent,
restoration and command test suites. Full local transcripts were retained as
`rk-dependency-staging-qualified-{stable,ci-sdk}.log`,
`rk-fleury-qualified-20261003-*.json` and the final archive-consumer report.
Earlier packet evidence above remains historical; this section is the final
implementation qualification.

Known boundaries remain explicit: SDK-mediated first-party runtime constraints
without original SDK manifest proof refuse; arbitrary path/Git runtime substitution
is unsupported; mixed-unit fresh repackaging can differ from immutable public
bytes because of tar timestamps. Retain the original stage for exact recovery, or
use separate units for genuinely fresh already-public and pending packages.
Existing frozen/tagged recovery requirements cannot be bypassed by regrouping.
