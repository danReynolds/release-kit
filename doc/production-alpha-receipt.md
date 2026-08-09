# Production alpha receipt

Status: not run

This is the evidence destination for the supervised release-kit canary in
`production-alpha-plan.md`. Do not turn either live checkpoint green from a
summary. Preserve the exact command transcript and public coordinates here.

The first recorded section must be titled "Release and provider receipt" and
include the clean pushed source commit, unit/version, stage identity, manifest
digest, configured adapters, target URLs, staged artifact inspection, release
transcript including the single native pub login preflight, and fresh-process
status read-back.

The second recorded section must be titled "Idempotent retry and consumer
receipt" and include the repeated release transcript showing zero public acts,
plus real consumption from pub.dev and the GitHub Release. Record Homebrew only
after a separately configured clean-consumer canary exercises it.

Replace every angle-bracketed instruction below with exact evidence. Keep
`Status: not run` until every field and transcript is complete; only then set
it to `Status: completed` and run the live checkpoint test.

## Release and provider receipt

Clean pushed source commit: <40-character lowercase commit hash>
Unit: <unit name>
Version: <semantic version>
Stage identity: <64-character lowercase SHA-256>
Manifest SHA-256: <64-character lowercase SHA-256>

Configured adapters: <exact adapter names>
Target URLs: <exact Git tag, pub.dev version, and GitHub Release URLs>

### Staged artifact inspection

```text
<complete `dart run bin/rk.dart release rk --stage` command and output, showing
no `dart pub login` invocation>
<the exact stage path printed by rk>
<`shasum -a 256` output for release-manifest.json>
<`shasum -a 256 -c SHA256SUMS` output, run from the stage directory>
<`tar -tzf` inventory for each of the three release archives>
<the extracted macOS `rk --version` output>
<`codesign --verify --strict --verbose=2` output for that binary>
<`codesign -d -r- --verbose=4` output for that binary>
<`codesign --test-requirement=notarized -v` output for that exact binary>
<the Accepted status and matching submission id from both macOS notary JSONs>
```

### Release transcript

```text
<complete `dart run bin/rk.dart release rk` command and settled output,
including exactly one attached `dart pub login` before the private-stage
boundary, followed by authorization, publish, and exact read-back; record no
credential or raw session values>
```

### Fresh-process status read-back

```text
<complete `dart run bin/rk.dart status rk` command and settled output>
```

## Idempotent retry and consumer receipt

Unit: <unit name>
Version: <semantic version>
Public acts: <exact integer; must be zero>
Asset: <one downloaded release archive filename>
Asset SHA-256: <64-character lowercase SHA-256>

### Repeated release transcript

```text
<complete repeated `dart run bin/rk.dart release rk` command and output,
showing the pub.dev target already exact, no second login or publish, and zero
public acts; login is not itself a public act or proof of uploader authority>
```

### pub.dev consumer

```text
<set `alpha_pub_cache` to a fresh temporary directory>
<`PUB_CACHE="$alpha_pub_cache" dart pub global activate release_kit <version>`>
<the public version URL>
<`"$alpha_pub_cache/bin/rk" --version` and output `rk <version>`>
<`"$alpha_pub_cache/bin/rk" --help` and its three-verb output>
```

### GitHub Release consumer

```text
<download both the chosen archive URL and the public SHA256SUMS URL into a
fresh directory>
<select that archive's public checksum line and show successful
`shasum -a 256 -c` output ending in `<asset>: OK`>
<extract the archive there and show the extracted `./rk --version` output as
`rk <version>` and `./rk --help` with the three-verb surface>
```
