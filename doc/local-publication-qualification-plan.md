# Local publication qualification

Status: implemented, independently reviewed and locally qualified, 2026-10-03.

## Goal and proof boundary

Exercise RK's shared CLI composition in a subprocess, the ordinary native Dart
Pub client, a loopback hosted registry, and a fresh native consumer through
staging, publication and recovery.
Use real package archives, version solving, HTTP uploads and downloads. Do not
intercept `dart pub publish`, fabricate native command successes, or claim this
qualifies pub.dev production authentication or GitHub's hosted service.

The existing native fixture exercises real solving and packaging, but installs
archives into its registry directly at the publication boundary. Retain that fast
coverage. Add a permanent, readable scenario repository and end-to-end tests that
close the process and upload boundary.

## Implementation plan

1. Reuse the current clean RK checkout on latest `origin/main` and a new branch.
   Review native publication protocol and RK endpoint ownership before code.
2. Compose a separate publication fixture alongside the existing native Pub
   fixture (keep its fast read-only behavior unchanged), with authenticated native
   uploads, immutable package versions, metadata and exact archive downloads.
   Keep request/event evidence, bounded failures, deterministic fault controls,
   disposable credentials/caches and no remote fallback. Uploaded archives must
   survive an RK process restart. Scope the server to loopback.
3. Add a checked-in fixture with independently versioned core, dependent library,
   test helper and executable. Include shared transitive dependencies and a
   development-only edge. Code must import and use dependencies so fresh consumer
   compilation/execution catches absent or incorrect payloads.
4. Extract the existing command body into `runRk`, keeping the shipped `main`
   fixed to pub.dev. The test-only entry point supplies one explicit, validated
   loopback endpoint to registry reads, target readiness and token matching.
   No endpoint flag or ambient configuration changes production target policy.
   Existing custom `publish_to` restrictions remain unchanged. An injected local
   session requires its own native token and never falls back to public login.
   Use real SystemTools and the ordinary SDK frontend for every native command.
   Register a synthetic environment-backed token for the local registry and
   isolate HOME/config/cache directories. A deny-all proxy rejects non-loopback
   native HTTP traffic; sanitize inherited proxy, bypass and credential settings.
   This qualifies shared parsing, composition and release behavior with a
   substituted service endpoint. Test shipped default routing separately.
5. Verify exact uploaded archive digests against staged artifacts, native registry
   download into an empty consumer cache, and consumer compilation/execution.
   Each retry invokes a fresh RK process against retained stage and server state.
6. Integrate the suite into CI with bounded runtime and useful failure transcripts.
   Document one local command, the fixture topology, supported faults and limits.
   Keep production changes minimal and independently tested when necessary.

## Required scenarios

- Whole-stack stage publishes nothing; release without consent uploads nothing.
- Compatible independent versions publish in dependency order and install from
  an empty cache; the consumer remains 0.1.0 while core is 0.2.0.
- Named consumer scope refuses while its staged runtime provider is unpublished.
- After publishing its runtime providers, named app release succeeds while its
  development-only helper remains staged and unpublished. The consumer's hosted
  package configuration must omit that helper.
- Accepted upload with a lost response reconciles exact registry truth without
  re-uploading or repackaging accepted versions.
- A rejected later upload preserves earlier published packages; after observing
  the subsequent absent-coordinate confirmation read, interrupt the owned RK
  process. A fresh process resumes with the exact original archives and completes
  the consumer journey. Harness status 130 means intentional cancellation.
- Metadata visibility and archive availability can differ. Interrupt the
  whole-stack propagation wait after the server answers an archive request with
  404. A named dependent must still refuse while that fault remains. Restore
  availability and resume the whole release without uploading accepted versions
  again; a fresh consumer must compile and run.
- A preexisting conflicting version/digest refuses without uploading over it.
- A bad published payload is detectable by the fresh consumer compile/run
  assertion (negative control rather than a claim that metadata proves code).
- Native missing-package solving and invalid-archive publication exit nonzero;
  accepted upload with lost finalization also exits nonzero before RK's separate
  reconciliation scenario proves recovery. These permanent controls must pass
  before accepting the full suite's result.

Prefer explicit event barriers and request-based fault schedules over sleeps.
Check stable observable contracts, not implementation-specific event counts.
Assert dependency partial order instead of a total order among unrelated units.
Released-under-test packages may enter the registry only through native uploads;
direct seeding is reserved for explicit preexisting/conflict negative fixtures.
Use the checked-in sources unchanged, no consumer dependency overrides, and a
fresh cache per successful or recovered consumer journey. Compare staged digests
with uploaded bytes and use dependency symbols in the consumer's expected output.

The registry implements native upload initiation, multipart upload and final
commit. Only finalization makes a version visible. Store the exact bytes once;
reject a conflicting immutable coordinate. Keep uploaded tickets separate from
accepted versions. For response loss, commit then drop the socket before headers
on every finalize request for that ticket; native `PUB_MAX_HTTP_RETRIES=1` bounds
the fixture without replacing transport failure with a fabricated exit code.
Control coordinate metadata, package-list metadata and archive availability
separately. Assert committed versions separately from attempted/retried requests.

## Reuse and scope

Share only process lifecycle, scenario observations and fault orchestration that
are demonstrated reusable. Pub implements Pub's actual HTTP protocol. Future npm
qualification must use npm's native client and a compatible registry protocol;
do not build a new dependency solver or speculative generic registry framework.
GitHub release transport qualification is separate: existing scripted coverage
remains, and this work does not create public releases or add a fake GitHub API.

## Review and acceptance

Independent reviewers examine endpoint safety/composition and protocol/scenario
coverage. Record actionable findings and the resulting plan revisions here
before implementation. After implementation, review the diff independently,
resolve findings, run focused native qualification plus appropriate existing
regressions and formatting/analyzer checks. Record passing commands and remaining
proof boundaries, then prepare a reviewable PR. No public package publication.

## Review log

- Architecture review identified that PUB_HOSTED_URL alone cannot exercise the
  production target: readiness, session and composition deliberately bind pub.dev.
  Independent reviewers selected explicit endpoint injection at shared CLI
  composition after a TLS transport spike failed native negative controls.
  Default target policy, explicit custom-destination restrictions, native solver
  behavior and staged artifact formats remain unchanged.
- Protocol review verified native Pub's initiate/multipart/finalize protocol,
  native environment-backed tokens, and its supported HTTP retry bound. Added
  commit-vs-upload semantics, persistent response loss and independent visibility
  controls so the recovery tests cannot pass on a simulated successful command.
- Kept the current read-only native fixture untouched and split protocol state
  from transport/process support to avoid broad regression risk.
- Scenario review required explicit proof rules: no directly seeded positive
  publications or consumer overrides, a fresh consumer cache for each recovered
  journey, digest equality and runtime output assertions, and dependency partial
  order rather than brittle request counts. Added these to acceptance.
- Scenario review clarified named-scope setup and dev-only behavior. Stage the
  full source before named refusal; then separately prove an unpublished helper
  does not block its app after runtime providers publish. The negative control
  is an API-incompatible separate hosted package that resolves but fails actual
  consumer compilation, not a claim that RK validates application behavior.
- Existing macOS CI is near its 20-minute limit. Run the tagged native publication
  suite serially in a dedicated bounded CI job rather than adding it to those
  jobs; retain local full-suite discoverability and a direct qualification command.
- Implementation review caught a false no-reupload assertion: accepted uploads
  excluded rejected duplicate attempts. Added a parsed `upload_attempted` event
  before rejection and assertions that cover all attempts, plus no initiation for
  exact-public no-ops.
- Implementation review found that awaiting a process with a timeout did not
  terminate it, and PPID inspection missed orphaned descendants. All fixture
  subprocesses now run in owned POSIX process groups via Python's standard
  library and are terminated as a group. Dedicated timeout tests cover both a
  waiting parent and an already-exited parent whose child retains output pipes.
- Actual execution revealed the existing ten-minute confirmation window after
  native upload failure and the same deadline for consumer availability polling.
  Retained production policy; made observed interruption an explicit scenario
  boundary. Normal rejection reporting remains covered by lower-level tests with
  injected waits; this suite does not wait out either wall-clock deadline.
  The unavailable-archive scenario separately selects a dependent while the
  fault persists, to exercise its native publication gate without selecting the
  provider's post-publication availability poll.
- A required negative control invalidated the direct dartdev AOT launcher:
  without the SDK frontend's SendPort, VmInteropHandler.exit is a no-op and
  native failures appear successful; native tool launching is affected too.
  Earlier successful uploads/downloads demonstrate transport only, not faithful
  native failure handling. Removed the launcher and TLS scaffolding rather than
  depending on the SDK's private frontend protocol. Permanent native failure
  controls and ordinary SDK execution are acceptance requirements.
- Final execution initially overlapped the last production source edits, which
  correctly changed RK's implementation fingerprint and invalidated saved stage
  identities. Frozen-source reproductions confirmed named refusal and exact
  archive reuse. Run qualification with the implementation fixed throughout;
  do not weaken stage identity checks to accommodate concurrent edits.

## Qualification record

The final frozen-source run on Dart 3.13.5 passed all 17 native publication and
harness tests in 8m09s:

```sh
dart test --tags publication --concurrency=1 --reporter=expanded
```

All nine harness/native failure controls and the propagation recovery scenario
also passed on Dart 3.12.2. The 154 existing release, staging, consent, catalog
and Pub inspection regressions passed; 29 focused endpoint, protocol, catalog
and Pub inspection tests passed. The protocol tests passed again after the final
response-barrier change. These groups overlap and are not a combined test count.

Formatting and analysis passed on the CI-pinned 3.12.2 SDK. The shipped CLI
compiled on 3.13.5 and its `--version` smoke test passed. Three independent
agents reviewed the plan and implementation; the final endpoint and propagation
revisions received additional review with no remaining blockers.

CI runs the serial native command in its dedicated publication job and keeps
endpoint/protocol regressions in the normal Linux/macOS suite. The proof boundary
and deadline exclusions above still apply. Earlier runs using the discarded
SDK-internal launcher do not count as native release qualification.
