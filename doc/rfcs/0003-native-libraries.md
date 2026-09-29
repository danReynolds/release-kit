# RFC 0003: Native libraries

> Engineering proposal, not yet built. Builds on RFC 0002 and changes none of
> its principles.

- Status: Draft for review
- Revision: 1 (2026-09-29)
- Scope: a Rust `cdylib` released as GitHub Release assets, and the Dart
  packages whose build hooks download those assets by digest
- First user: Flark 0.5 — the `flark_parse` crate and the `flark` package
- Proposed in three increments; each can be accepted or rejected on its own

## Summary

A Dart package with a native build hook can spare its consumers a compiler:
the hook downloads a prebuilt library for the target it is building and
verifies it against a digest the package pins. A release is then two public
acts in a fixed order: publish the libraries, then publish a package that pins
them. The second act is the permanent one. rk handles neither today. Its only
build adapter compiles Dart CLIs, and nothing checks that a package's pin
agrees with the libraries it names.

This RFC proposes:

1. **Pin verification.** Before a package with a pin goes to pub.dev, rk proves
   three things. The pin names a public, immutable release. That release
   serves the pinned bytes. The staged archive contains that exact pin. rk
   builds nothing in this increment.
2. **Library production.** A `cargo` ecosystem and a `cargo-cdylib` build
   adapter. A library unit is staged, drafted, bound to its tag, published and
   read back like a binary unit today. The dependent package's edge to it is
   derived from its pin.
3. **Attested import.** A platform the operator's machine cannot build can be
   produced by a CI run at the exact commit. rk admits the artifact only when a
   GitHub artifact attestation binds it to that repository, workflow and
   commit. Authorization and publication stay local.

## The failures

These are ranked by probability times cost, per principle 8. Each was observed
while preparing Flark 0.5.0 for release. Evidence is from the independent
review of that release branch (Flark PR #59, 2026-09-29).

1. **A published package pins bytes its consumers cannot get.** A pub.dev
   version is permanent. If its pin is empty, names the wrong tag, or carries a
   digest from a different build, every consumer without a Rust toolchain fails
   to build that version for good. The only remedy is the next version.
   - Flark commits an empty pin, which is the correct development state, and
     nothing in rk stopped `rk release flark` from publishing it. Flark now
     guards this with a changelog convention and a test. Every repository
     would have to reinvent that guard.
   - Its pinning script hashes a local directory and trusts that it matches what
     was uploaded.
   - Its build script reused a previous run's Windows libraries whenever their
     directory existed. They had consistent hashes, so nothing flagged them.
2. **The package goes public before its libraries do.** The same consequence
   follows if the libraries' release is still a draft, or its assets are
   replaced after pinning. This failure is reached through ordering, not
   content.
3. **The libraries were built from different source than the package's
   bindings describe.** Flark generates its Dart schema constants from the
   crate. A crate change after the libraries were released would ship Dart code
   for a render model the pinned library does not produce, and users would find
   it at runtime.
   - Flark's documented `gh release create` had no `--target`, so the library
     tag named the default branch's HEAD rather than the commit that built the
     libraries.
   - Nothing tied a pin to crate source.
4. **Fleet drift.** Flark's procedure is two scripts, a CI job and a manual
   sequence. This is RFC 0002's third failure. The review found two
   build-configuration defects in it that a shared adapter would settle once:
   - Apple libraries embedded the builder's absolute path as their install
     name.
   - Windows libraries depended on the Visual C++ runtime DLLs.
5. **A platform cannot be produced on the operator's machine.** A Mac links
   MSVC Windows libraries only through a third-party tool, after the operator
   accepts Microsoft's SDK license. Flark's Windows libraries therefore come from
   a CI job and are carried into the release by hand, and nothing binds them to
   the commit.

Increment 1 prevents failures 1 and 2, and the part of failure 3 that concerns
tags. Increment 2 prevents all of failure 3 and failure 4. Increment 3 answers
failure 5.

## Shape: two units, two commits

A library and the package that pins it are separate release units with
separate tags:

```toml
schema = 2

[release.parser]
path = "native/flark_parse"
tag = "flark_parse-v{version}"
publish = ["git-tag", "github-release"]
library_platforms = [
  "macos-arm64", "macos-x64",
  "ios-arm64", "ios-arm64-simulator", "ios-x64-simulator",
  "android-arm64", "android-arm", "android-x64",
  "linux-x64", "linux-arm64",
  "windows-x64", "windows-arm64",
]

[release.flark]
path = "packages/flark"
tag = "flark-v{version}"
publish = ["git-tag", "pub.dev"]
```

The pin is part of the package's source, so it must be committed before the
package is staged. It can only be written after the libraries are public.

A single unit would need rk to write into the tree between two of its own
steps. The tag, the source snapshot and the pub archive would then describe
different trees. Two units keep every identity rule RFC 0002 has:

- the library release is tagged on the commit that built it, A;
- the pin is committed on top of it, as commit B;
- the package is tagged, packaged and published from B.

```text
rk release parser    stage at A, draft, verify, publish; tag flark_parse-v0.5.0 → A
rk pin flark         write the pin; the operator reviews and commits it as B
rk release flark     verify the pin against public reality; stage at B; pub.dev
```

The package needs no configuration for this. Its pin names the library
release's tag. When that tag matches a unit in the same repository, rk derives
the edge. The package unit then waits for the library unit's public reality,
the way a first-party pub dependency waits today.

`rk status flark` at A reports the pin as the blocking prerequisite and names
`rk release parser`. After that it names `rk pin flark`. At B it reports the
package ready. A single `rk release` invocation cannot cross the commit
between the two units. It stops after the libraries and names the next
action.

## The pin

rk owns one small schema, so that rk, build hooks and any other reader agree
on it. The file is canonical JSON, the encoding rk already uses for
`release-manifest.json`. It lives at a conventional path in the package,
`hook/native_libraries.json`:

```json
{
  "libraries": {
    "android-arm64": {"name": "flark_parse-0.5.0-android-arm64.so", "sha256": "…", "size": 1480312},
    "macos-arm64": {"name": "flark_parse-0.5.0-macos-arm64.dylib", "sha256": "…", "size": 1203456}
  },
  "release": {
    "manifest_sha256": "…",
    "repository": "danReynolds/flark",
    "tag": "flark_parse-v0.5.0"
  },
  "schema": 1
}
```

- **`libraries`** is keyed by rk platform name.
  - A hook downloads
    `https://github.com/<repository>/releases/download/<tag>/<name>` and checks
    its size and SHA-256 before using it. Flark's hook already does this; only
    the keys change, from Rust triples to platform names.
  - For a release rk produced, `libraries` must equal the release's
    `native-library` artifacts, not a subset of them. A platform the release
    built and the package omits is a mismatch, not a choice.
- **`manifest_sha256`** is the digest that the library release's annotated tag
  carries (`release-manifest-sha256:`, RFC 0002's tag binding). With it, anyone
  can authenticate the pin from Git alone: tag, then manifest, then assets.
  It is null for a release rk did not produce.
- **The path is conventional, not configured.** It is a contract between rk
  and every hook in the fleet. A setting would be per-repository variation with
  no failure to name.

A package is subject to this RFC exactly when it contains the file. Reading a
conventional file is not discovery. rk already reads `CHANGELOG.md` and
`pubspec_overrides.yaml` this way.

## Increment 1: pin verification

The pin is read from the source snapshot. It becomes a public-reality
prerequisite of the package's pub.dev step, with the new frozen step form
`<unit>/requires/github-release/<repository>/<tag>`. It is inspected before
authorization and again immediately before the act, like any prerequisite.

| Verdict | When |
|---|---|
| `exact` | The release is public and reports immutable. Each pinned asset's downloaded bytes match its size and digest. For a release rk produced, the tag binding and the manifest agree with the pin. |
| `absent` | There is no such tag or release, or it is still a draft. rk names the command that publishes it, when a unit derives it. |
| `conflict` | The pin disagrees with an intact public release. The remedy is to re-pin, a source change. |
| `conflict`, terminal | The release is mutable, lacks a pinned asset, or serves different bytes. It cannot be repaired in place, so the remedy is a new library version. |
| `unknown` | GitHub could not be read. This is never collapsed into `absent`. |

In addition:

- **The file must be well formed.** It is parsed strictly: unknown keys,
  non-canonical encoding and malformed digests are refused. The empty
  development pin is valid source, but a pub.dev step refuses it with its own
  code. This is the mechanical answer to Flark's review finding.
- **The staged archive must contain the verified pin.** The pub archive must
  contain `hook/native_libraries.json` with exactly the verified bytes. Without
  this, a `.pubignore` could publish a package whose hook cannot find its pin.
- **Declared platforms must be covered.** Each native platform in the
  pubspec's `platforms:` needs at least one pinned library. Flutter's default
  release build uses several ABIs at once: Android arm64, arm and x64, and
  macOS arm64 and x64. A missing default ABI is a warning, and open item 1 asks
  whether it should refuse.
- **Bytes are downloaded, not trusted from metadata.** Each pinned asset is
  downloaded once per run and hashed. This follows RFC 0002: asset names alone
  are not exactness, and neither is a reported digest.

This fits RFC 0002's architecture as one more prerequisite kind, read through
the existing GitHub client. That client's `readBoundAsset` already proves a
downloaded asset against an authenticated digest. Codes are a new `RK-NATIVE`
family.

## Increment 2: producing libraries

### Ecosystem: `cargo`

A `cargo` project is one whose path holds a `Cargo.toml`. Its facts come from
native sources, per principle 1:

- **Identity.** Name, version, library name and crate types come from
  `cargo metadata --format-version 1 --no-deps --locked`. That is the native
  tool's JSON, as `dart pub deps --json` is for Dart. rk's TOML subset is for
  `release.toml` and does not grow to Cargo's grammar.
- **Version.** The crate's `package.version` must be canonical SemVer. The
  unit's tag derives from it as for Dart.
- **Crate type.** It must include `cdylib`.
- **Lockfile.** `Cargo.lock` is required, since this is a compiled-binary unit
  under RFC 0002's lockfile rule, and every build passes `--locked`.
- **Toolchain.** It comes from `rust-toolchain.toml` or `rust-toolchain`, the
  ecosystem's own file, and rk falls back to rustup's default. Either way, the
  stage records `rustc -vV` and the resolved compiler's digest, as it records
  the Dart compiler.
- **Changelog.** `CHANGELOG.md` in the crate directory needs an entry for the
  version.
- **Workspaces.** A Cargo workspace member works: `path` names the member.

RFC 0002's module-layout amendment removed an ecosystem seam that had one
member. This reintroduces it with two, each justified by the failures above.

### Build adapter: `cargo-cdylib`

Each platform builds in its own lane, over a copy of the stage's source
snapshot:

```text
cargo build --release --locked --lib --target <triple> --manifest-path <path>/Cargo.toml
```

rk does not pass cargo the operator's environment. It constructs one from
four parts:

- the toolchain homes;
- a target directory inside the lane;
- `--remap-path-prefix` for the lane root, so outputs carry no stage paths;
- the platform settings below.

Ambient `RUSTFLAGS`, `CARGO_BUILD_*`, `CARGO_PROFILE_*` and linker variables
therefore cannot change output without appearing in the plan. A global
`-C target-cpu=native` would otherwise publish libraries that crash on older
processors.

Optimization, LTO, panic strategy and symbol stripping belong to the crate's
own `[profile.release]`. The native manifest owns them, and rk adds nothing
beyond the closed set here.

Platform vocabulary is closed. Its names are the public asset names:

| platform | Rust target | adapter-owned settings |
|---|---|---|
| `macos-arm64`, `macos-x64` | `aarch64-apple-darwin`, `x86_64-apple-darwin` | deployment target; `@rpath/<library>` install name |
| `ios-arm64` | `aarch64-apple-ios` | deployment target; install name |
| `ios-arm64-simulator`, `ios-x64-simulator` | `aarch64-apple-ios-sim`, `x86_64-apple-ios` | deployment target; install name |
| `android-arm64`, `android-arm`, `android-x64` | `aarch64-linux-android`, `armv7-linux-androideabi`, `x86_64-linux-android` | NDK API level |
| `linux-x64`, `linux-arm64` | `x86_64-unknown-linux-gnu`, `aarch64-unknown-linux-gnu` | glibc floor |
| `windows-x64`, `windows-arm64` | `x86_64-pc-windows-msvc`, `aarch64-pc-windows-msvc` | static C runtime |

**Floors are a compatibility contract.** They work like the Dart CLI's glibc
floor. rk builds at a fixed floor per platform and records it in the stage and
the release manifest; it does not take the floor from configuration. The
proposed floors are the lowest Flutter supports: macOS 10.15, iOS 12.0 and
Android API 21. Flark's script uses exactly these. For Linux the floor is the
glibc of rk's Linux build image. The install name and the static C runtime
settle failure 4's two defects for every library.

Capabilities are discovered per platform and reported, as RFC 0002's binary
chain reports them:

- **Native.** The host platform.
- **Cross-compiled.**
  - Apple platforms on macOS with Xcode.
  - Android with an NDK: `ANDROID_NDK_HOME`, else the newest under
    `ANDROID_HOME/ndk`.
  - Linux in a container runtime, using rk's pinned build image.

  Each also needs the target's standard library for the resolved toolchain.
  rk reports the `rustup target add` command and does not run it. Installing a
  toolchain component is a change to the machine, which the operator makes, as
  with installing Xcode.
- **Blocked.** Everything else, naming what is missing. Windows MSVC targets
  are blocked off Windows: linking them needs the Windows SDK, and rk does not
  accept a license on the operator's behalf. Increment 3 addresses this.

Proof is per platform:

- Every output's format is checked against its target: Mach-O, ELF or PE; the
  machine type; a dynamic library; the install name, or no SONAME path leak;
  and, on Windows, no C runtime imports.
- On the host platform, rk also loads the library through `dart:ffi`, the
  smoke test's analogue.
- The rest are buildable but unproven, exactly as cross-compiled Dart CLIs
  are. That absence is stated on the step, at the prompt and in the document.

Nothing is signed or notarized. The application that embeds a library signs
it: Flutter signs native assets into the app bundle, and notarization applies
to the distributed app.

### Publication

This reuses the existing machinery:

- **Assets.** Libraries are raw GitHub Release assets, not archives, because a
  hook downloads one file and hashes it.
- **Names.** Each asset is named `<library>-<version>-<platform>.<ext>` and is
  frozen once public, per `ReleaseAssets`.
- **Manifest.** Each library is typed `native-library` in
  `release-manifest.json`, which also records its platform and floor. That is
  a schema version bump for a public document.
- **Unchanged parts.** The tag binding, the draft, the immutability check and
  the post-publish re-download are RFC 0002's.
- **Step ids.** A unit may give `library_platforms` to at most one project, as
  it may `binary_platforms`. `<unit>/build/<platform>` stays unambiguous and
  needs no new form.

### The dependent package

When the pin names a unit in the same repository, increment 1's verification
gains two checks:

- **Exactness.** The pin equals the release's `native-library` artifacts,
  authenticated through the tag binding.
- **Source continuity.** The tree at the library unit's `path` must be the same
  in the package's commit and in the manifest's `source.commit`. If the crate
  changed after its libraries were released, the package would ship bindings
  for native code no release contains. That is refused, and the remedy is to
  release the libraries again and re-pin. This is the rest of failure 3.

### Writing the pin

The pin is source, so a person commits it. rk's job is to make the correct pin
something to read rather than compute:

- `rk status <unit> --json` carries the expected pin document whenever the pin
  is absent or mismatched.
- `rk pin <unit>` writes exactly that document. Besides `init`, it would be the
  only verb that writes source, and `release` never invokes it.

It replaces per-repository scripts such as Flark's `write_prebuilt_manifest.py`
(failure 4). Open item 4 asks whether the status document alone is enough.

## Increment 3: attested import

For a platform blocked on this machine, `library_platforms` is still the
product decision; only production moves.

1. The project's CI builds those platforms from the exact commit, with GitHub
   artifact attestations (`actions/attest-build-provenance`).
2. rk stages on the operator's machine. It finds the run of the declared
   workflow whose head is the commit being staged, and downloads the named
   artifact.
3. rk admits each file only when `gh attestation verify` proves three things:
   the subject digest is the file's SHA-256; the attestation was issued for
   this repository; and it came from the declared workflow file at this commit.

The stage records the attestation and the run as evidence. `rk status` and the
release manifest say where each platform was produced, which is RFC 0002's
fourth CI seam: assurance is a recorded fact. The draft, verification, tag
binding and authorization still happen locally, and the imported libraries get
the same format proof as cross-compiled ones.

Configuration names only where provenance comes from, not a command:

```toml
[release.parser.attested]
workflow = ".github/workflows/libraries.yml"
platforms = ["windows-x64", "windows-arm64"]
```

This is RFC 0002's deferred CI work arriving for production only. The
attestation is an external authority binding bytes to a commit. That is
identity of provenance, not acceptability. Without it, a Mac-hosted fleet
either cannot ship Windows libraries or carries them by hand with nothing
binding them to the commit, which is what happened in failure 1.

## Alternatives rejected

- **rk runs the project's build script.** Configuration would then hold a
  command. The script's outputs would be acceptable, not identified, and every
  repository would keep its own release code. That violates principles 5 and
  8, and RFC 0002's third failure.
- **One unit, with rk injecting the pin into the pub archive.** The published
  package would differ from its tagged source.
- **A pin that names only the tag.** A build hook would then have to
  authenticate a Git tag, which it has no way to do. Digests in the pin let a
  hook verify with no authority beyond the package itself.
- **Bundling the libraries in the pub archive.** Dart supports this, and it
  needs no rk change. Every consumer would download every platform, forever,
  in every version. Flark chose download at build time; nothing here prevents
  bundling.

## Not proposed

- Publishing crates to crates.io. That would be a separate target proposal.
- Other native build systems, such as CMake or Zig. The ecosystem seam admits
  them, and each would name its own failure.
- Committed web binaries, such as Flark's `flark_parse.wasm`, which is
  verified today by the project's transport tests. See open item 7.

## Flark, migrated

- **Before increment 2.** Flark's 0.5.0 can use increment 1 alone:
  1. Publish the libraries with its scripts.
  2. Write the pin in this schema.
  3. rk proves the pin before `flark` reaches pub.dev.
- **With increment 2:**
  - `release.toml` gains the `parser` unit above.
  - `hook/prebuilt.json` becomes `hook/native_libraries.json`, and the hook's
    download step reads platform keys. Its bundled, `prebuilt_dir` and crate
    fallbacks do not change.
  - `build_release_libraries.sh` and `write_prebuilt_manifest.py` retire.
- **With increment 3.** The CI job's Windows libraries gain attestations and
  are imported. Today they are downloaded by hand.

## Open items

1. **ABI completeness.** Should a missing default ABI refuse or warn?
2. **Floors.** Should a project be able to raise a floor? And which Linux image
   and glibc should rk use? Flark uses Debian bullseye, glibc 2.31.
3. **Pin location.** Is `hook/native_libraries.json` right, given that only
   Dart hooks read it today?
4. **`rk pin`.** Is the verb needed, or is the expected pin in status JSON
   enough?
5. **Unrecorded releases.** Should increment 1 keep accepting releases rk did
   not produce after increment 2 exists, or require the tag binding?
6. **Reproducibility.** Rebuilding a platform and comparing digests would
   upgrade reuse from "the stage's receipt" to "reproduced". Rust `cdylib`s are
   often but not always byte-reproducible, and nothing above depends on it.
7. **Committed Wasm.** Should rk rebuild committed Wasm modules and compare
   them, which needs the same reproducibility?
8. **Standalone macOS use.** Should macOS libraries be Developer ID signed for
   use outside Flutter, where no app signs them?
