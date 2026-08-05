# Diagnostic codes

Every refusal rk makes carries a code. They are a published interface: they
ride in the `--json` document under `problems[]`, they are what an operator
greps when rk stops, and `engine/diagnostic.dart` commits to never reusing
one for a different meaning.

They are declared where they fire, not in a central table — each producer
names its own, and all are reported in one pass. This index exists because
search cost is not a failure but an unindexed vocabulary is.

Hand-maintained, and checked both ways by `dart run tool/validate.dart`: a
declared code missing from this table fails, a row here that nothing declares
fails, and the count below is checked against the rows.

111 codes across 25 families.


## RK-AUTH — Authorization

| code | says | declared in |
|---|---|---|
| `RK-AUTH-001` | nobody is here to authorize this release | `lib/src/commands/release.dart` |

## RK-BREW — The Homebrew tap

| code | says | declared in |
|---|---|---|
| `RK-BREW-001` | the tap formula was not updated | `lib/src/binary_chain.dart` |
| `RK-BREW-002` | the tap was updated and could not be read back | `lib/src/binary_chain.dart` |
| `RK-BREW-003` | the public tap does not hold what rk pushed | `lib/src/binary_chain.dart` |

## RK-BUILD — The build

| code | says | declared in |
|---|---|---|
| `RK-BUILD-001` | $platform: the build did not produce a working binary | `lib/src/binary_chain.dart` |

## RK-CHG — The changelog

| code | says | declared in |
|---|---|---|
| `RK-CHG-001` | "$packageName" has no changelog | `lib/src/engine/changelog.dart` |
| `RK-CHG-002` | the changelog has no entry for $version | `lib/src/engine/changelog.dart` |
| `RK-CHG-003` | the release body was not prepared | `lib/src/commands/release.dart` |
| `RK-CHG-004` | the changelog entry for ${project.version} is empty | `lib/src/commands/release.dart` |

## RK-CLI — How rk was invoked

| code | says | declared in |
|---|---|---|
| `RK-CLI-001` | rk does not have ${unknown.join( | `bin/rk.dart` |
| `RK-CLI-002` | this is not a git repository | `bin/rk.dart` |
| `RK-CLI-003` | no unit named "$only" | `lib/src/commands/release.dart` |
| `RK-CLI-004` | name the unit to release | `lib/src/commands/release.dart` |
| `RK-CLI-005` | rk $command does not have ${inapplicable.join( | `bin/rk.dart` |
| `RK-CLI-006` | --at names one release, and this repository has  ${units.length} units | `lib/src/commands/verify.dart` |
| `RK-CLI-007` | — | `bin/rk.dart` |

## RK-CONF — release.toml, structurally

| code | says | declared in |
|---|---|---|
| `RK-CONF-001` | release.toml must declare its schema version | `lib/src/engine/config.dart` |
| `RK-CONF-002` | this rk understands schema ${ReleaseConfig.supportedSchema},  and this file declares $va… | `lib/src/engine/config.dart` |
| `RK-CONF-003` | unknown setting "$key" | `lib/src/engine/config.dart` |
| `RK-CONF-004` | release.toml declares no release units | `lib/src/engine/config.dart` |
| `RK-CONF-005` | "release" must hold units, as in [release.core] | `lib/src/engine/config.dart` |
| `RK-CONF-006` | unit name "$name" is not usable | `lib/src/engine/config.dart` |
| `RK-CONF-007` | unit "$name" must be a table, as in [release.$name] | `lib/src/engine/config.dart` |
| `RK-CONF-008` | unknown setting "$key" in unit "$name" | `lib/src/engine/config.dart` |
| `RK-CONF-009` | unit "$name" declares a project inline and also as rows | `lib/src/engine/config.dart` |
| `RK-CONF-010` | unit "$name" has a malformed project list | `lib/src/engine/config.dart` |
| `RK-CONF-011` | unit "$name" releases nothing | `lib/src/engine/config.dart` |
| `RK-CONF-012` | unit "$name" releases several projects, so its tag cannot be derived | `lib/src/engine/config.dart` |
| `RK-CONF-013` | the tag pattern for "$unit" must be text | `lib/src/engine/config.dart` |
| `RK-CONF-014` | the tag pattern for "$unit" must contain {version} exactly once | `lib/src/engine/config.dart` |
| `RK-CONF-015` | the tag pattern for "$unit" uses a placeholder rk does not have | `lib/src/engine/config.dart` |
| `RK-CONF-016` | — | `lib/src/engine/config.dart` |
| `RK-CONF-017` | a project path in "$unit" must be text | `lib/src/engine/config.dart` |
| `RK-CONF-018` | the project path "$value" leaves the repository | `lib/src/engine/config.dart` |
| `RK-CONF-019` | a project in "$unit" does not say where to publish | `lib/src/engine/config.dart` |
| `RK-CONF-020` | publish must be a list of channels | `lib/src/engine/config.dart` |
| `RK-CONF-021` | a project in "$unit" publishes to nothing | `lib/src/engine/config.dart` |
| `RK-CONF-022` | unknown channel "$channel" | `lib/src/engine/config.dart` |
| `RK-CONF-023` | "$channel" is listed twice | `lib/src/engine/config.dart` |
| `RK-CONF-024` | homebrew needs github-release, which hosts the archives it points at | `lib/src/engine/config.dart` |
| `RK-CONF-025` | a project in "$unit" ships binaries but names no platforms | `lib/src/engine/config.dart` |
| `RK-CONF-026` | a project in "$unit" names platforms but ships no binaries | `lib/src/engine/config.dart` |
| `RK-CONF-027` | binary_platforms must be a non-empty list | `lib/src/engine/config.dart` |
| `RK-CONF-028` | unknown platform "$platform" | `lib/src/engine/config.dart` |
| `RK-CONF-029` | "$platform" is listed twice | `lib/src/engine/config.dart` |
| `RK-CONF-032` | $key must be text | `lib/src/engine/config.dart` |
| `RK-CONF-033` | git will not accept the tag pattern for "$unit": $issue | `lib/src/engine/config.dart` |
| `RK-CONF-034` | release.toml is there and rk could not read it | `bin/rk.dart` |
| `RK-CONF-035` | unit "$name" declares code_id but signs nothing | `lib/src/engine/config.dart` |
| `RK-CONF-036` | unit "$name" declares homebrew_tap but does not publish to  homebrew | `lib/src/engine/config.dart` |
| `RK-CONF-037` | $key is empty | `lib/src/engine/config.dart` |

## RK-DART — Dart-specific facts

| code | says | declared in |
|---|---|---|
| `RK-DART-201` | "${pubspec.name}" is built from sources this repository does not  contain | `lib/src/engine/resolve.dart` |

## RK-DEP — Dependencies between units

| code | says | declared in |
|---|---|---|
| `RK-DEP-001` | "${project.name}" requires $name ${dependency.constraint}, and  this repository releases… | `lib/src/engine/checklist.dart` |
| `RK-DEP-002` | rk cannot tell whether "${project.name}" accepts $name  ${sibling.version}: it requires … | `lib/src/engine/checklist.dart` |
| `RK-DEP-003` | the packages in "${unit.name}" depend on each other in a circle,  so there is no order t… | `lib/src/engine/checklist.dart` |

## RK-GIT — The repository

| code | says | declared in |
|---|---|---|
| `RK-GIT-001` | — | `lib/src/engine/git.dart` |
| `RK-GIT-002` | $step needs an origin remote, and this repository has none | `lib/src/commands/release.dart` |
| `RK-GIT-003` | this repository has no remote | `lib/src/engine/git.dart` |
| `RK-GIT-004` | ${unit.version} is already published, and the tag  ${unit.tag} does not exist | `lib/src/engine/inspect.dart` |
| `RK-GIT-005` | the tag ${unit.tag} points at ${_short(target)}, and this  release would publish from ${… | `lib/src/engine/inspect.dart` |
| `RK-GIT-006` | the repository could not be listed | `lib/src/commands/init.dart` |

## RK-HOST — What this machine can produce

| code | says | declared in |
|---|---|---|
| `RK-HOST-001` | this machine cannot produce $platform | `lib/src/binary_chain.dart` |

## RK-INIT — init

| code | says | declared in |
|---|---|---|
| `RK-INIT-001` | the config rk would propose is one rk itself refuses | `lib/src/commands/init.dart` |
| `RK-INIT-002` | release.toml already exists | `lib/src/commands/init.dart` |
| `RK-INIT-003` | nothing here can be released | `lib/src/commands/init.dart` |

## RK-INT — rk itself

| code | says | declared in |
|---|---|---|
| `RK-INT-001` | rk failed in a way it does not have a message for: $error | `bin/rk.dart` |

## RK-MONO — Version monotonicity

| code | says | declared in |
|---|---|---|
| `RK-MONO-001` | the tag $tag is ahead of ${unit.version}, which this release  would publish | `lib/src/engine/inspect.dart` |
| `RK-MONO-002` | ${project.name} ${latest.version} is already published, and this  would publish ${projec… | `lib/src/engine/inspect.dart` |

## RK-NOTARY — Notarization

| code | says | declared in |
|---|---|---|
| `RK-NOTARY-001` | $platform: the archive for notarization failed | `lib/src/binary_chain.dart` |
| `RK-NOTARY-002` | $platform: notarization did not complete | `lib/src/binary_chain.dart` |
| `RK-NOTARY-003` | $platform: Apple accepted the submission and the log  could not be fetched | `lib/src/binary_chain.dart` |

## RK-PKG — The package as pub sees it

| code | says | declared in |
|---|---|---|
| `RK-PKG-001` | this manifest declares no package name | `lib/src/engine/pubspec.dart` |
| `RK-PKG-002` | — | `lib/src/engine/pubspec.dart` |

## RK-PUB — Publishing to pub.dev

| code | says | declared in |
|---|---|---|
| `RK-PUB-001` | pub refuses to publish ${project.name} | `lib/src/commands/release.dart` |
| `RK-PUB-002` | ${project.name}: consumers could not resolve this | `lib/src/commands/release.dart` |
| `RK-PUB-003` | ${project.name}: dart pub publish did not complete | `lib/src/commands/release.dart` |
| `RK-PUB-004` | ${project.name} ${project.version}: published, and the  archive could not be read back | `lib/src/commands/release.dart` |

## RK-REG — The registry

| code | says | declared in |
|---|---|---|
| `RK-REG-001` | ${project.name}: ${error.message} | `lib/src/commands/verify.dart` |
| `RK-REG-003` | ${project.name} has never been published, and a first publish is  not rk\ | `lib/src/commands/release.dart` |

## RK-REL — The release run

| code | says | declared in |
|---|---|---|
| `RK-REL-001` | ${first.summary}:  ${state.detail ?? state.verdict.name} | `lib/src/commands/release.dart` |

## RK-RES — The config resolved against the repository

| code | says | declared in |
|---|---|---|
| `RK-RES-001` | no package at "${declared.path}" | `lib/src/engine/resolve.dart` |
| `RK-RES-002` | "${pubspec.name}" declares no version, so there is nothing to release | `lib/src/engine/resolve.dart` |
| `RK-RES-003` | "${pubspec.name}" sets publish_to: none but is asked to publish to  pub.dev | `lib/src/engine/resolve.dart` |
| `RK-RES-004` | "${pubspec.name}" ships binaries but declares no executable | `lib/src/engine/resolve.dart` |
| `RK-RES-005` | "${pubspec.name}" declares ${pubspec.executables.length} executables,  so rk cannot tell… | `lib/src/engine/resolve.dart` |
| `RK-RES-006` | — | `lib/src/engine/resolve.dart` |
| `RK-RES-007` | the package "$name" is declared by two projects | `lib/src/engine/resolve.dart` |
| `RK-RES-008` | the projects in "${unit.name}" are at different versions:  ${versions.join( | `lib/src/engine/resolve.dart` |
| `RK-RES-009` | ${shipping.length} projects in "${unit.name}" ship binaries | `lib/src/engine/resolve.dart` |
| `RK-RES-010` | the units "${first.name}" and "${unit.name}" would share the tag  "${unit.tagPattern}" | `lib/src/engine/resolve.dart` |

## RK-SIGN — Signing identity

| code | says | declared in |
|---|---|---|
| `RK-SIGN-001` | the published release names no team rk can read | `lib/src/binary_chain.dart` |
| `RK-SIGN-002` | $platform: signing failed | `lib/src/binary_chain.dart` |
| `RK-SIGN-003` | the signature does not match the identity users  already installed | `lib/src/binary_chain.dart` |
| `RK-SIGN-004` | the identity users already installed could not be read | `lib/src/commands/release.dart` |
| `RK-SIGN-005` | code_id disagrees with the release users already installed | `lib/src/commands/release.dart` |
| `RK-SIGN-006` | the login keychain could not be read | `lib/src/commands/release.dart` |
| `RK-SIGN-007` | no Developer ID Application certificate is installed | `lib/src/commands/release.dart` |
| `RK-SIGN-008` | this machine has ${certificates.length} Developer ID  certificates and nothing published says which distributes this | `lib/src/commands/release.dart` |
| `RK-SIGN-009` | no release states what this program is called | `lib/src/commands/release.dart` |

## RK-TAG — The tag

| code | says | declared in |
|---|---|---|
| `RK-TAG-001` | the tag ${unit.tag} could not be created | `lib/src/commands/release.dart` |
| `RK-TAG-002` | the tag ${unit.tag} could not be pushed | `lib/src/commands/release.dart` |
| `RK-TAG-003` | the push reported success, and origin does not list  ${unit.tag} | `lib/src/commands/release.dart` |

## RK-TOML — The TOML subset

| code | says | declared in |
|---|---|---|
| `RK-TOML-001` | — | `lib/src/engine/toml.dart` |

## RK-VER — Verification

| code | says | declared in |
|---|---|---|
| `RK-VER-001` | the ref $ref does not exist, so there is no source to  prove the published version again… | `lib/src/commands/verify.dart` |
| `RK-VER-002` | ${project.name} has no readable version at $ref | `lib/src/commands/verify.dart` |
| `RK-VER-003` | ${project.name} $atRef is not on pub.dev, so there is  nothing to verify | `lib/src/commands/verify.dart` |
| `RK-VER-004` | ${project.name} ${project.version}: $tampered | `lib/src/commands/release.dart` |
| `RK-VER-005` | ${project.name} $atRef could not be fully proved | `lib/src/commands/verify.dart` |
| `RK-VER-006` | ${project.name} ${project.version}:  ${comparison.detail ?? | `lib/src/commands/release.dart` |

## RK-WORK — The workspace

| code | says | declared in |
|---|---|---|
| `RK-WORK-001` | the workspace has no $name | `lib/src/binary_chain.dart` |

## RK-YAML — The YAML subset

| code | says | declared in |
|---|---|---|
| `RK-YAML-001` | — | `lib/src/engine/yaml.dart` |
