#!/usr/bin/env bash
# Makes the throwaway repository a demo tape records, and prints its path.
# Nothing here is pushed anywhere but a local bare repository, or published.
#
#   setup.sh init      this repository's HEAD, without its release.toml
#   setup.sh example   the README's two packages, cli depending on core
#   setup.sh use       a clone of this repository's HEAD
#   setup.sh fleury    Fleury's four packages, each one patch version ahead
#                      ($FLEURY: a Fleury checkout, ../fleury by default)
set -euo pipefail
here=$(pwd)

case "${1:-}" in
init)
  dir=$(mktemp -d)/release-kit
  mkdir -p "$dir"
  git archive HEAD | tar -x -C "$dir"
  cd "$dir"
  rm release.toml
  git init -q
  git add -A
  git -c commit.gpgsign=false commit -qm 'release-kit without release.toml'
  git remote add origin https://github.com/danReynolds/release-kit.git
  ;;
example)
  dir=$(mktemp -d)/example
  mkdir -p "$dir"
  cp -R "$here/examples/workspace-with-dependent/." "$dir"
  cd "$dir"
  mkdir -p packages/cli/bin
  echo 'void main() => print("example 0.3.0");' > packages/cli/bin/example.dart
  cat > release.toml <<'EOF'
schema = 3

[release.core]
path = "packages/core"
publish = ["pub.dev"]

[release.cli]
path = "packages/cli"
publish = ["git-tag", "pub.dev", "github-release", "homebrew"]
binary.platforms = ["macos-arm64", "linux-x64", "linux-arm64"]
EOF
  git init -q -b main
  git add -A
  git -c commit.gpgsign=false commit -qm 'Two packages, cli depending on core'
  git remote add origin https://github.com/example/example.git
  ;;
use)
  dir=$(mktemp -d)/release-kit
  git clone -q "$here" "$dir"
  git -C "$dir" remote set-url origin https://github.com/danReynolds/release-kit.git
  ;;
fleury)
  source=$(cd "${FLEURY:-../fleury}" && pwd)
  dir=$(mktemp -d)/fleury
  git clone -q "$source" "$dir"
  cd "$dir"
  git fetch -q "$(git -C "$source" remote get-url origin)" main
  git checkout -q -B main FETCH_HEAD
  python3 - <<'EOF'
import pathlib, re
packages = ['fleury', 'fleury_mcp', 'fleury_test', 'fleury_web']
def bump(v):
    major, minor, patch = v.split('.')
    return f'{major}.{minor}.{int(patch) + 1}'
versions = {}
for name in packages:
    text = pathlib.Path(f'packages/{name}/pubspec.yaml').read_text()
    versions[name] = re.search(r'^version: (\S+)$', text, re.M).group(1)
for name in packages:
    pubspec = pathlib.Path(f'packages/{name}/pubspec.yaml')
    text = re.sub(r'^version: \S+$', f'version: {bump(versions[name])}',
                  pubspec.read_text(), flags=re.M)
    for dep, old in versions.items():  # exact pins on a sibling follow it
        text = re.sub(rf'^(  {dep}: ){re.escape(old)}$',
                      rf'\g<1>{bump(old)}', text, flags=re.M)
    pubspec.write_text(text)
    changelog = pathlib.Path(f'packages/{name}/CHANGELOG.md')
    rest = changelog.read_text().removeprefix('# Changelog\n')
    changelog.write_text(
        f'# Changelog\n\n## {bump(versions[name])}\n\n- Demo.\n' + rest)
EOF
  git -c commit.gpgsign=false commit -qam 'Demo: one patch version ahead'
  # A local origin that has the commit, as a real release's would.
  git init -q --bare "$dir.origin.git"
  git remote set-url origin "$dir.origin.git"
  git push -q -u origin main
  ;;
*)
  echo "usage: setup.sh init|example|use|fleury" >&2
  exit 2
  ;;
esac
echo "$dir"
