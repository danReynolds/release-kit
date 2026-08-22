# Production release receipt: rk 0.1.4

Status: completed
Date: 2026-08-21
Unit: rk
Version: 0.1.4
Source commit: 4118904ad0827b854f1d9200fdaf5fa924e62bb7
Release PR: https://github.com/danReynolds/release-kit/pull/50
Tag object: f7f3adff75f1a44df1107fd296c7f93e43b70aab
Stage identity: ed53e252c2e1f97e38b3bb0219b388fdc6a15661df8bfd791cbfd4e09810ea95
Manifest SHA-256: af61e56a53c3014660790cb919dad6ef2efc4d83faf022fa8616d1b8471450aa
Notary submission ID: d0f083fe-af5b-4cc2-ac4a-dc959dc21d79

This receipt closes the supervised production canary described in
[production-alpha-plan.md](production-alpha-plan.md). The source commit is the
commit bound into the stage, tag, manifest, and public artifacts. This receipt
is a post-release record and therefore lands after that tagged commit.

## Implementation and CI

The release source passed:

- `dart format --output=none --set-exit-if-changed .`;
- `dart analyze` with no issues;
- `dart test` with 970 passing tests; and
- GitHub CI on Ubuntu and macOS for release PR 50.

The 0.1.4 change added the final macOS artifact gate. The signed executable
passed its smoke test, passed strict signature verification after that
execution, was archived, and passed strict signature verification again after
rk decoded the final archive into a new directory.

Signed smoke: pass
Post-smoke signature verification: pass
Archive-extracted signature verification: pass
Notarization requirement: pass
Certificate: Developer ID Application: Pollyn Inc (5AHFA9FUZG)
Certificate SHA-256: 801984bb3b6a1592280ed7d581225a60543cf0b189c362893361963b1319d622
macOS executable SHA-256: 9d5b60fb6484a5e9ac5ed0cf230851f23a7e8bdea60e244ae4311bc5ec2371a0
Notary result: Accepted

The earlier 0.1.3 signature warning was reproduced and found to be a sandbox
false negative: the restricted process could not access macOS trust/keychain
services. Outside that boundary, the exact staged binary passed strict
verification and its CodeDirectory hashes matched its bytes. The stronger
0.1.4 checks were retained because verifying the final archive is the right
release invariant regardless.

## Stage artifacts

| Artifact | SHA-256 | Result |
|---|---|---|
| `rk-0.1.4-linux-arm64.tar.gz` | `18cb59621d9100b143b6573afd3e873e4da17ce4ed5eabc9f1285642f0df8ac3` | manifest match; inventory exact |
| `rk-0.1.4-linux-x64.tar.gz` | `3725ae9316445dbdd10298528a3b0556e8f9eca118f40727cf61f669838056d0` | manifest match; inventory exact |
| `rk-0.1.4-macos-arm64.tar.gz` | `1cf5c67f6fce119e915f98d0eb50f1337ec24fedab510176c565c64ee824ba68` | manifest match; inventory exact; extracted signature valid |
| pub.dev package archive | `f8e9224330457e99855eb40201b1f76ee25b4706dc60ae711a1f0043683fdd09` | public archive exact |
| `Casks/rk.rb` | `42f13b7626e2dd83ab5025039f658286921ace20c5b316661f53462daf405d17` | tap identity exact |

Every binary archive contained exactly `rk`, `LICENSE`, and `README.md`. The
macOS archive was independently extracted and its executable reported
`rk 0.1.4`, passed `codesign --verify --strict`, and satisfied
`codesign -vvvv -R='notarized' --check-notarization`.

Linux smoke execution was not available during staging because no container
runtime was running on the macOS producer. Linux compilation and archive
validation passed, and the implementation/test suite ran on Ubuntu CI. This
was recorded as `not-executed`, not promoted to a false local pass.

## Public reconciliation

| Target | Public coordinate | Read-back |
|---|---|---|
| Git tag | `v0.1.4` | annotated tag binds source commit and manifest |
| pub.dev | https://pub.dev/packages/rk/versions/0.1.4 | published archive matches staged package |
| GitHub Release | https://github.com/danReynolds/release-kit/releases/tag/v0.1.4 | metadata and all four asset bytes match |
| Homebrew | https://github.com/danReynolds/homebrew-tap/blob/main/Casks/rk.rb | cask points at 0.1.4 with exact staged identity |

pub.dev accepted the upload before its cached versions endpoint exposed it.
rk's bounded 60-second read-back stopped the release with an uncertain effect,
so GitHub Release and Homebrew did not incorrectly proceed from an unproved
dependency. Approximately two minutes later, the package reconciled as exact
and the same release safely completed.

An idempotent `dart run bin/rk.dart release rk --json` retry exited 0 with no
problems or warnings. Its four public steps — Git tag, pub.dev, GitHub Release,
and Homebrew — each reported `verdict: exact` and
`action: already_published`. Public acts on retry: 0.

## Clean consumers

| Source | Isolation | Evidence | Result |
|---|---|---|---|
| pub.dev | fresh `PUB_CACHE` | activate `rk 0.1.4`; run version and bare-name status | pass |
| GitHub Release | fresh download/extraction directory | manifest digest; signature; notarization; version; bare-name status | pass |
| Homebrew | clean native Apple Silicon cask install | `/opt/homebrew/bin/rk --version`; signature; notarization; bare-name status | pass |
| Installed CLI | user PATH installation | exact GitHub binary digest; `rk --version` | pass |

All three public consumers reported `rk 0.1.4` and successfully ran
`rk status rk` against a clean checkout, observing Git tag, pub.dev, GitHub
Release, and Homebrew as published. The installed CLI at
`/Users/dan/.local/bin/rk` was replaced with the independently verified GitHub
binary and has the recorded macOS executable digest.

The machine also has an Intel Homebrew at `/usr/local`; it correctly refused
the arm64-only cask. The native `/opt/homebrew` installation is the relevant
consumer and completed successfully.

## Conclusion

The 0.1.4 canary proves the full supported lifecycle: reviewed source, green
cross-platform CI, source-bound private staging, signed and notarized final
archive bytes, dependency-aware public publication, uncertain-effect recovery,
idempotent reconciliation, and clean consumption from every distribution
channel. rk is ready for supervised production use within that target and
platform boundary.
