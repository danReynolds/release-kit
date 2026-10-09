# Diagnostic codes

Every structured finding rk makes carries a code. They are a published
interface: they ride in the `--json` document under `problems[]` or
`warnings[]`, they are what an operator or agent keys on when rk stops, and
`engine/diagnostic.dart` commits to never reusing one for a different meaning.

They are declared where they fire, not in a central table — each producer
names its own, and all are reported in one pass. This index exists because
search cost is not a failure but an unindexed vocabulary is.

Hand-maintained, and checked both ways by `test/codes_index_test.dart`: a
declared code missing from this table fails, a row here that nothing declares
fails, and the count below is checked against the rows.

105 codes across 27 families.


## RK-AUTH — Authorization

| code | says | declared in |
|---|---|---|
| `RK-AUTH-001` | nobody is here to authorize this release | `lib/src/commands/release_publication_coordinator.dart` |
| `RK-AUTH-002` | the release was not authorized | `lib/src/commands/release_publication_coordinator.dart` |

## RK-BREW — The Homebrew tap

| code | says | declared in |
|---|---|---|
| `RK-BREW-001` | the tap formula was not updated | `lib/src/targets/homebrew/module.dart` |
| `RK-BREW-002` | the tap was updated and could not be read back | `lib/src/targets/homebrew/module.dart` |
| `RK-BREW-003` | the public tap does not hold what rk pushed | `lib/src/targets/homebrew/module.dart` |

## RK-BUILD — The build

| code | says | declared in |
|---|---|---|
| `RK-BUILD-001` | $platform: the build did not produce a working binary | `lib/src/binary_chain.dart` |
| `RK-BUILD-002` | $platform was built but not executed | `lib/src/commands/release_publication_coordinator.dart` |
| `RK-BUILD-003` | a project's own build failed, could not start, or could not make its cache | `lib/src/asset_build.dart` |
| `RK-BUILD-004` | a project's own build did not write every asset it declares | `lib/src/asset_build.dart` |

## RK-CHG — The changelog

| code | says | declared in |
|---|---|---|
| `RK-CHG-001` | the changelog has no entry for this version, or there is no changelog | `lib/src/engine/changelog.dart` |
| `RK-CHG-003` | the release body was not prepared | `lib/src/targets/github_release/module.dart`, `lib/src/targets/github_release/release_notes_stage.dart` |
| `RK-CHG-004` | the changelog entry for ${project.version} is empty | `lib/src/targets/github_release/release_notes_stage.dart` |

## RK-CLEAN — Local staged release work

| code | says | declared in |
|---|---|---|
| `RK-CLEAN-001` | the local stage path is not safe to clean | `lib/src/commands/clean.dart` |
| `RK-CLEAN-002` | another rk command is using staged work | `lib/src/commands/clean.dart` |
| `RK-CLEAN-003` | staged work changed or could not be completely removed | `lib/src/commands/clean.dart` |
| `RK-CLEAN-004` | nobody is here to authorize cleanup | `lib/src/commands/clean.dart` |
| `RK-CLEAN-005` | partially completed releases may need the staged bytes | `lib/src/commands/clean.dart` |

## RK-CLI — How rk was invoked

| code | says | declared in |
|---|---|---|
| `RK-CLI-001` | rk does not have ${unknown.join( | `bin/rk.dart` |
| `RK-CLI-003` | no unit named "$only" | `lib/src/commands/plan.dart`, `lib/src/commands/release.dart`, `lib/src/commands/status.dart` |
| `RK-CLI-005` | rk $command does not have ${inapplicable.join( | `bin/installations.dart`, `bin/rk.dart` |
| `RK-CLI-007` | — | `bin/rk.dart` |
| `RK-CLI-008` | rk has no command named "$command" | `bin/rk.dart` |
| `RK-CLI-009` | rk does not support a release choice named "$name" | `lib/src/commands/target.dart` |

## RK-CONF — release.toml, structurally

| code | says | declared in |
|---|---|---|
| `RK-CONF-002` | the schema line is missing, or names a schema this rk cannot read | `lib/src/engine/config.dart` |
| `RK-CONF-003` | a setting or a target is in a table that does not hold it | `lib/src/engine/config.dart` |
| `RK-CONF-005` | a value is missing, the wrong shape, or not one rk accepts | `lib/src/engine/config.dart` |
| `RK-CONF-009` | settings that require or exclude one another | `lib/src/engine/config.dart` |

## RK-DART — Dart-specific facts

| code | says | declared in |
|---|---|---|
| `RK-DART-201` | "${pubspec.name}" is built from sources this repository does not  contain | `lib/src/engine/resolve.dart` |

## RK-DEP — Dependencies between units

| code | says | declared in |
|---|---|---|
| `RK-DEP-003` | the packages in "${unit.name}" depend on each other in a circle, so there is no order t… | `lib/src/engine/release_dependencies.dart` |
| `RK-DEP-004` | the release units depend on each other in a circle | `lib/src/engine/release_dependencies.dart` |

RK-DEP-002 (a version constraint Pub cannot parse, which Pub reports when it
stages the package) is retired and not reused.

## RK-GIT — The repository

| code | says | declared in |
|---|---|---|
| `RK-GIT-001` | — | `lib/src/engine/git.dart` |
| `RK-GIT-002` | a publishing target needs an origin remote, and this repository has none | `lib/src/targets/github_release/module.dart`, `lib/src/targets/homebrew/formula_stage.dart`, `lib/src/targets/homebrew/module.dart` |
| `RK-GIT-003` | this repository has no remote | `lib/src/engine/git.dart` |
| `RK-GIT-004` | ${unit.version} is already published, and the tag  ${unit.tag} does not exist | `lib/src/engine/inspect.dart` |
| `RK-GIT-005` | the tag ${unit.tag} points at ${_short(target)}, and this  release would publish from ${… | `lib/src/commands/status.dart`, `lib/src/engine/inspect.dart` |
| `RK-GIT-007` | the tag exists, and rk could not read which commit it names | `lib/src/engine/inspect.dart` |
| `RK-GIT-008` | the worktree state could not be read | `lib/src/engine/git.dart` |
| `RK-GIT-009` | $tag was released from ${_short(releasedFrom)}, and its release is unfinished | `lib/src/engine/inspect.dart` |
| `RK-GIT-006` | the repository could not be listed | `lib/src/commands/init.dart` |

## RK-GITHUB — GitHub Releases

| code | says | declared in |
|---|---|---|
| `RK-GITHUB-010` | the GitHub CLI has no usable session | `lib/src/targets/github_release/module.dart` |

## RK-HOST — What this machine can produce

| code | says | declared in |
|---|---|---|
| `RK-HOST-001` | this machine cannot produce $platform | `lib/src/commands/release.dart`, `lib/src/commands/status.dart` |

## RK-INIT — init

| code | says | declared in |
|---|---|---|
| `RK-INIT-001` | the config rk would propose is one rk itself refuses | `lib/src/commands/init.dart` |
| `RK-INIT-003` | nothing here can be released | `lib/src/commands/init.dart` |
| `RK-INIT-004` | release.toml appeared before rk could write it | `lib/src/commands/init.dart` |
| `RK-INIT-005` | .gitignore changed while init was being reviewed | `lib/src/commands/init.dart` |
| `RK-INIT-006` | release.toml was written but .gitignore was not updated | `lib/src/commands/init.dart` |

## RK-INT — rk itself

| code | says | declared in |
|---|---|---|
| `RK-INT-001` | rk failed in a way it does not have a message for: $error | `bin/installations.dart`, `bin/rk.dart` |

## RK-MONO — Version monotonicity

| code | says | declared in |
|---|---|---|
| `RK-MONO-001` | the tag $tag is ahead of ${unit.version}, which this release  would publish | `lib/src/targets/git_tag/module.dart` |
| `RK-MONO-002` | ${project.name} ${project.version} is behind published version  $publicVersion | `lib/src/targets/pub_dev/module.dart` |
| `RK-MONO-003` | a public target is ahead of the version this release would publish | `lib/src/targets/git_tag/module.dart`, `lib/src/targets/target_module.dart` |
| `RK-MONO-004` | current source still declares a released version | `lib/src/targets/git_tag/module.dart` |

## RK-NOTARY — Notarization

| code | says | declared in |
|---|---|---|
| `RK-NOTARY-001` | $platform: the archive for notarization failed | `lib/src/binary_chain.dart` |
| `RK-NOTARY-002` | $platform: notarization did not complete | `lib/src/binary_chain.dart` |
| `RK-NOTARY-004` | the rk-notary credential is not ready | `lib/src/commands/release_stage_coordinator.dart` |

RK-NOTARY-003 (an accepted submission whose log could not be fetched) and
RK-NOTARY-005 (the delayed Gatekeeper ticket warning) are retired historical
meanings and are not reused.

## RK-PKG — The package as pub sees it

| code | says | declared in |
|---|---|---|
| `RK-PKG-001` | the manifest is not one rk can read: YAML it cannot parse, or no package name | `lib/src/engine/cargo.dart`, `lib/src/engine/pubspec.dart`, `lib/src/engine/yaml.dart` |
| `RK-PKG-002` | — | `lib/src/engine/cargo.dart`, `lib/src/engine/pubspec.dart` |

## RK-PUB — Publishing to pub.dev

| code | says | declared in |
|---|---|---|
| `RK-PUB-001` | pub refuses to publish ${project.name} | `lib/src/targets/pub_dev/package_stage.dart` |
| `RK-PUB-003` | ${project.name}: dart pub publish did not complete | `lib/src/targets/pub_dev/module.dart` |
| `RK-PUB-005` | the published coordinate could not be confirmed after acting | `lib/src/targets/pub_dev/module.dart` |
| `RK-PUB-006` | the immutable public archive differs from the staged native archive | `lib/src/targets/pub_dev/module.dart` |
| `RK-PUB-007` | dart pub login did not complete | `lib/src/targets/pub_dev/session.dart` |
| `RK-PUB-009` | the native Dart configuration redirects pub.dev publication | `lib/src/targets/pub_dev/module.dart` |
| `RK-PUB-010` | a pub.dev package points to another repository | `lib/src/targets/pub_dev/module.dart` |
| `RK-PUB-011` | this Dart SDK cannot stage the native Pub archive | `lib/src/targets/pub_dev/module.dart`, `lib/src/targets/pub_dev/package_stage.dart` |
| `RK-PUB-012` | pub validation reported a package warning | `lib/src/targets/pub_dev/package_stage.dart` |
| `RK-PUB-014` | ${project.name} resolves with Flutter packages, and the Dart rk uses is not part of a Flutter SDK | `lib/src/targets/pub_dev/package_stage.dart` |
| `RK-PUB-017` | Pub cannot resolve $package the way its consumers do | `lib/src/targets/pub_dev/package_stage.dart` |
| `RK-PUB-019` | Pub could not resolve dependencies or reach the registry for ${project.name} | `lib/src/targets/pub_dev/package_stage.dart` |

RK-PUB-002 (the consumer-resolve probe) and RK-PUB-004 are retired historical
meanings and are not reused. So are RK-AUTH-003, RK-DEST-001, RK-SIGN-013 and
RK-STAGE-004, the checks a release once repeated between staging and each act.

## RK-REL — The release run

| code | says | declared in |
|---|---|---|
| `RK-REL-001` | ${first.summary}:  ${state.detail ?? state.verdict.name} | `lib/src/commands/release_publication_coordinator.dart`, `lib/src/commands/status.dart`, `lib/src/engine/inspect.dart`, `lib/src/targets/git_tag/module.dart`, `lib/src/targets/github_release/module.dart`, `lib/src/targets/homebrew/module.dart`, `lib/src/targets/pub_dev/module.dart` |
| `RK-REL-003` | a public target could not be proven after rk acted | `lib/src/commands/release_publication_coordinator.dart`, `lib/src/targets/target_module.dart` |

## RK-RES — The config resolved against the repository

| code | says | declared in |
|---|---|---|
| `RK-RES-001` | no package at "${declared.path}" | `lib/src/engine/resolve.dart` |
| `RK-RES-002` | a manifest declares no version rk can release, such as a workspace root's or a crate's inherited one | `lib/src/engine/cargo.dart`, `lib/src/engine/resolve.dart` |
| `RK-RES-003` | a package that sets publish_to: none, or names a custom registry, is asked to publish to pub.dev | `lib/src/engine/resolve.dart` |
| `RK-RES-004` | a binary project's pubspec lacks what its build reads: exactly one executable, and each dart_defines field | `lib/src/engine/resolve.dart` |
| `RK-RES-006` | a package is declared twice, by path or by name, or projects nest | `lib/src/engine/resolve.dart` |
| `RK-RES-008` | the projects in "${unit.name}" are at different versions:  ${versions.join( | `lib/src/engine/resolve.dart` |
| `RK-RES-009` | a unit's GitHub release assets come from more than one project | `lib/src/engine/resolve.dart` |
| `RK-RES-010` | the units "${first.name}" and "${unit.name}" would share the tag  "${unit.tagPattern}" | `lib/src/engine/resolve.dart` |
| `RK-RES-016` | a Cargo crate is released only through its declared build | `lib/src/engine/resolve.dart` |

## RK-SIGN — Signing identity

| code | says | declared in |
|---|---|---|
| `RK-SIGN-001` | the published release names no team rk can read | `lib/src/commands/release_stage_coordinator.dart` |
| `RK-SIGN-002` | $platform: signing failed | `lib/src/binary_chain.dart` |
| `RK-SIGN-003` | the signature does not match the identity users  already installed | `lib/src/binary_chain.dart` |
| `RK-SIGN-014` | the signed binary does not run | `lib/src/binary_chain.dart` |
| `RK-SIGN-017` | the code hash of $file could not be read | `lib/src/binary_chain.dart` |
| `RK-SIGN-004` | the identity users already installed could not be read | `lib/src/commands/release_stage_coordinator.dart` |
| `RK-SIGN-006` | the login keychain could not be read | `lib/src/commands/release_stage_coordinator.dart` |
| `RK-SIGN-007` | no Developer ID Application certificate is installed | `lib/src/commands/release_stage_coordinator.dart` |
| `RK-SIGN-008` | this machine has ${certificates.length} Developer ID  certificates and nothing published says which distributes this | `lib/src/commands/release_stage_coordinator.dart` |
| `RK-SIGN-009` | no release states what this program is called | `lib/src/commands/release_stage_coordinator.dart` |
| `RK-SIGN-010` | no certificate for the team the published release names | `lib/src/commands/release_stage_coordinator.dart` |
| `RK-SIGN-011` | several certificates for the published team | `lib/src/commands/release_stage_coordinator.dart` |

RK-SIGN-012 (the certificate's SHA-256 fingerprint, read only to be compared
with itself) and RK-SIGN-015, RK-SIGN-016, RK-SIGN-018 and RK-SIGN-019, checks
that read back signatures rk had just written, are retired and not reused.

## RK-SRC — Source binding

| code | says | declared in |
|---|---|---|
| `RK-SRC-003` | release.toml or another release input is there and could not be read | `lib/src/engine/release_source.dart` |
| `RK-SRC-004` | there is no commit to stage or release | `lib/src/engine/git.dart` |

## RK-STAGE — The private release stage

| code | says | declared in |
|---|---|---|
| `RK-STAGE-001` | the release stage could not be located or replaced safely | `lib/src/commands/release.dart`, `lib/src/commands/release_stage_coordinator.dart` |
| `RK-STAGE-002` | the reviewed release stage no longer validates, or changed before an act | `lib/src/commands/release_publication_coordinator.dart`, `lib/src/commands/release_stage_coordinator.dart`, `lib/src/commands/status.dart` |
| `RK-STAGE-003` | committed release bytes could not be staged or did not remain valid | `lib/src/commands/release.dart`, `lib/src/commands/release_stage_coordinator.dart` |
| `RK-STAGE-005` | a partial release of built assets lost the exact stage it needs, or the public inputs that let it finish without one changed | `lib/src/commands/release.dart`, `lib/src/commands/release_publication_coordinator.dart`, `lib/src/commands/status.dart` |
| `RK-STAGE-006` | staged work is locked or its fixed path is unsafe | `bin/rk.dart` |

## RK-TAG — The tag

| code | says | declared in |
|---|---|---|
| `RK-TAG-001` | the tag ${unit.tag} could not be created | `lib/src/targets/git_tag/transaction.dart` |
| `RK-TAG-002` | the tag ${unit.tag} could not be pushed | `lib/src/targets/git_tag/transaction.dart` |
| `RK-TAG-005` | this project signs its release tags, and no signing key is configured | `lib/src/targets/git_tag/transaction.dart` |

## RK-TOML — The TOML subset

| code | says | declared in |
|---|---|---|
| `RK-TOML-001` | — | `lib/src/engine/toml.dart` |

## RK-WORK — The workspace

| code | says | declared in |
|---|---|---|
| `RK-WORK-001` | the staged workspace has no required target artifact | `lib/src/binary_chain.dart`, `lib/src/targets/github_release/module.dart`, `lib/src/targets/homebrew/formula_stage.dart` |

## Executable installations

| Code | Meaning | Source |
| --- | --- | --- |
| `RK-USE-001` | an installation operation was refused or failed | `bin/installations.dart` |
| `RK-USE-002` | installation files or metadata could not be read | `bin/installations.dart` |
