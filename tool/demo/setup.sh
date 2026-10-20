#!/usr/bin/env bash
# Makes the throwaway repository a demo tape records, and prints its path.
# Nothing here is pushed or published.
#
#   setup.sh init     this repository's HEAD, without its release.toml
#   setup.sh fleury   Fleury's four packages, each one patch version ahead,
#                     in a local commit ($FLEURY: a Fleury checkout,
#                     ../fleury by default)
set -euo pipefail

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
fleury)
  source=$(cd "${FLEURY:-../fleury}" && pwd)
  dir=$(mktemp -d)/fleury
  git clone -q "$source" "$dir"
  cd "$dir"
  git remote set-url origin "$(git -C "$source" remote get-url origin)"
  git fetch -q origin
  git checkout -q --detach origin/main
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
  ;;
*)
  echo "usage: setup.sh init|fleury" >&2
  exit 2
  ;;
esac
echo "$dir"
