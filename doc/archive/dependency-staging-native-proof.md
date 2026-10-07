# Native dependency staging qualification

> Archived. Superseded by [practical staging](../practical-staging.md), which
> replaced rk's own dependency resolution and archive staging with Pub.

This record distinguishes native mechanism tests, integrated command tests and
actual Fleury dogfooding. It does not qualify a real public upload or browser
rendering. The [architecture map](dependency-staging-plan.md) and
[release contract](repository-release-plan.md) describe the implementation.
Earlier intermediate hashes and delivery notes remain in Git history.

## Native mechanism and SDK coverage

The initial mechanism was measured on macOS arm64 on 2026-10-02. Hosted metadata
discovery delegates selection and backtracking to Pub; replay preloads the actual
archives under their original hosted identities. Discovery payloads contain only
manifests and never reach compilation or publication.

`native_hosted_staging_test.dart` exercises a consumer at 0.1.0 using a provider
at 0.2.0, compiling and running the consumer with unchanged published manifests.
Its native cases cover transitive staged dependencies, legitimate backtracking,
conflicts, explicit registries, excluded provider files, ignored provider dev
dependencies, unpublished dev helpers and metadata/archive graph disagreement.
The graph comparison covers dependency edges, not just selected coordinates.

| SDK | Pinned Pub revision | Native mechanism qualification |
| --- | --- | --- |
| 3.10.4, RK minimum | `f7f1891e2de3d795532f45ec214f88ac912ffcd6` | Nine original native cases passed; later scoped archive/public-consumer cases also passed |
| 3.12.2, pinned formatting/analysis SDK | `74408212b5348003381bc63f3b59274aaa23cfa3` | Nine native cases and seven alternative-mechanism probes passed; full suite qualified below |
| 3.13.5, stable checked 2026-10-02 | `ec276d10a7fa0f6c6ec005340fb9ad29f3b012d0` | Nine native cases passed; full suite qualified below |

Revisions come from the tagged SDKs' `DEPS`. The pinned
[Pub publication implementation](https://github.com/dart-lang/pub/blob/74408212b5348003381bc63f3b59274aaa23cfa3/lib/src/command/lish.dart)
and [hosted archive preload](https://github.com/dart-lang/pub/blob/74408212b5348003381bc63f3b59274aaa23cfa3/lib/src/source/hosted.dart)
explain two design constraints: `--from-archive` skips validation, so RK needs an
explicit pre-upload public consumer gate; `pub get --dry-run` downloads packages,
so it cannot be used as a metadata-only discovery primitive.

A native workspace was rejected as the binding mechanism: it can shadow a
same-name dependency from another registry and reject an otherwise supported SDK
lower bound. Managed path overrides alone do not prove original constraints.
`native_dependency_staging_test.dart` preserves these alternative probes.

Run the committed native mechanism tests with:

```sh
dart test test/native_dependency_staging_test.dart test/native_hosted_staging_test.dart
```

Select another native SDK while retaining the normal test runner with:

```sh
RK_NATIVE_DART=/absolute/path/to/dart dart test test/native_hosted_staging_test.dart
```

`RK_NATIVE_PROOF_REPORT=/absolute/path/report.json` records hashes and SDK output
for the backtracking/packaging/compile case. Native tar hashes identify the exact
run; they are not a promise of reproducible bytes across runs or SDKs.

## Integrated boundaries

Production tests use the guarded archive reader, source-bound discovery and
frozen replay. Their loopback registries have no public upload endpoint or remote
fallback. Fixtures own their Git roots, caches, servers and child processes.

The public-boundary cases verify exact staged provider archives before and after
a fresh external consumer solve. They also cover a same-version consumer
replacement, unavailable public dependencies, development/workspace exclusion,
broad runtime ranges and racing providers. The 25 standalone cases and three
composed package cases passed on stable 3.13.5 and minimum 3.10.4. These are scoped
native checks, not full-suite minimum-SDK qualification.

The consumer probe preloads only the proposed consumer under its hosted identity
with a consumer-only synthetic lock. It verifies source, version, digest, package
location and extracted inventory after solving. Broad-range public choices are
transient evidence and cannot replace a frozen private binding. Failures return
`RK-PUB-018` before the target is marked attempted.

An SDK-only fixture proves that standalone Dart actually tries the public solve
and reports the unavailable Flutter SDK. SDK runtime paths reaching staged
first-party providers remain unsupported because the frozen SDK graph lacks the
original hosted constraints needed to prove those obligations. Runtime path/Git
substitution also remains unsupported.

Mixed-unit tests distinguish provider eligibility from reproduction of outputs.
An already-public package is a hosted input, but the complete-unit contract still
packages every configured output. Tar mtimes may change its raw archive digest;
release then refuses before consent. Exact saved partial stages resume without
repackaging. A tagless public package alone does not prove prior staging of its
siblings; exact configured tags and built-asset progress remain recovery-critical.
See [ordering and recovery](repository-release-plan.md#ordering-and-recovery).

## Final qualification — 2026-10-03

Implementation commit `f5b2c46` completed the publication boundary.
Qualification-only documentation followed at `27be516` without changing the RK
implementation digest.
Both independent reviewers approved the production boundaries after iterating on
recovery consent, local-only scope guards and mixed-package unit progress.

- Full `dart test`: **1,885 passed, one opt-in Homebrew installation test skipped**
  on each of Dart **3.13.5** and CI SDK **3.12.2**, on macOS arm64. These are two
  executions of the same suite, not additive coverage. CI's disposable macOS
  runner separately enables its real Homebrew installation check.
- [Remote CI at `27be516`](https://github.com/danReynolds/release-kit/actions/runs/37105065910)
  passed on Linux and macOS, including terminal workflow qualification.
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
This section records the implementation qualification at the commit and digest
above; subsequent review fixes have their own evidence below.

Known boundaries remain explicit: SDK-mediated first-party runtime constraints
without original SDK manifest proof refuse; arbitrary path/Git runtime substitution
is unsupported; mixed-unit fresh repackaging can differ from immutable public
bytes because of tar timestamps. Retain the original stage for exact recovery, or
use separate units for genuinely fresh already-public and pending packages.
Existing frozen/tagged recovery requirements cannot be bypassed by regrouping.

## Review cleanup — 2026-10-03

A second, independent three-reviewer pass reviewed native resolution, stage
recovery and repository publication against current main, then cross-reviewed
one another's changes. Fix commit `86890fe` addresses these reproduced defects:

- A changed stage in a later pending unit could escape the repository consent
  guard before an earlier unit published.
- A native check could replace a valid reviewed receipt/archive or add a warning
  after the consent check. Final provider reads could likewise hide endpoint or
  compiler drift. All pending inputs are now rechecked before public action.
- A custom `publish_to` root rejected a valid back-edge to its own registry.
- Malformed registry metadata leaked signed archive URL tokens through decoder
  errors. Diagnostics now redact the body; permanently cached shadow failures
  fail once instead of consuming Pub's retry budget (29.07 s versus 0.99 s in the
  measured malformed-metadata case).
- A completed receipt could exceed the lookup reader's 4 MiB bound and become
  unrestorable. A 15,000-file fixture reproduced a successful 4,366,867-byte
  receipt followed by failed lookup. Shared read/write bounds and source-inventory
  preflight now refuse before copying source, preserving the readable header.

The pass also removed the advisory intent index, unused consent paths and
redundant identity/source-step construction. A complete bounded scan was already
required to detect ambiguous or unclassifiable stages; the index only reordered
reads. Legacy index residue remains ignored without changing stage choices.
The design documentation now describes the current contract rather than mixing
it with superseded proposals and progress logs.

Focused verification passed 252 stage/recovery tests, 192 orchestration/status
checks, two actual CLI consent tests, and 44 native tests on each of Dart 3.13.5
and 3.10.4. These groups overlap and are not additive coverage counts. Eleven new
consent regressions exercise changes after approval, session acquisition, native
verification and the final provider read, including valid stage replacement and
safe scope shrink after public completion. Analyzer, pinned formatting and
cross-review found no remaining blocker. Final full-suite, CI and renewed Fleury
results for this revision are recorded in [PR #94](https://github.com/danReynolds/release-kit/pull/94).
