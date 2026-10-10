#!/usr/bin/env python3
"""Export the compiler-reported source closure for this one temporary preview.

Usage: package.py SDK_SOURCE DEPS_DIRECTORY PACKAGE_CONFIG DEPFILE OUTPUT
The SDK and DEPS checkouts must match SDK tag 3.13.5. Apply the archived patch
and compile main.dart.in as main.dart with --depfile before running this tool.
Rebuild the exported sources with rebuild.sh; do not distribute the first build.
"""

import json
from pathlib import Path
import re
import shlex
import shutil
import sys
from urllib.parse import unquote, urlparse


def main():
    sdk, deps, config, depfile, output = map(Path, sys.argv[1:])
    sdk, deps = sdk.resolve(), deps.resolve()
    output.mkdir()  # Refuse to overwrite a previous package.
    here = Path(__file__).resolve().parent
    repo = here.parent.parent
    files = {Path(p).resolve() for p in shlex.split(
        depfile.read_text().split(': ', 1)[1])}
    mappings = []
    provenance = []
    notices = [('RK helper', (repo / 'LICENSE').read_text())]
    revisions = dict(re.findall(r'"(\w+)_rev": "([0-9a-f]+)"',
                                (sdk / 'DEPS').read_text()))
    for package in json.loads(config.read_text())['packages']:
        root = Path(unquote(urlparse(package['rootUri']).path)).resolve()
        used = sorted(p for p in files if p.is_relative_to(root))
        if not used:
            continue
        name = package['name']
        if root.is_relative_to(sdk):
            origin, revision, origin_root = (
                'dart-lang/sdk', '04bcd1036cdc799ac6564988f159ee454d42c822', sdk)
        else:
            dependency = root.relative_to(deps).parts[0]
            origin = ('simolus3/' if dependency == 'tar' else 'dart-lang/') + dependency
            revision, origin_root = revisions[dependency], deps / dependency
        destination = output / 'packages' / name
        for source in used:
            target = destination / source.relative_to(root)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
        shutil.copyfile(root / 'pubspec.yaml', destination / 'pubspec.yaml')
        license_file = root / 'LICENSE'
        if not license_file.is_file():
            license_file = origin_root / 'LICENSE'
        shutil.copyfile(license_file, destination / 'LICENSE')
        notices.append((name, license_file.read_text()))
        provenance.append({'package': name, 'repository': origin,
                           'revision': revision,
                           'path': str(root.relative_to(origin_root))})
        mappings.append({**package, 'rootUri': f'packages/{name}/'})
        files.difference_update(used)
    # Only the entry point and original package map may be outside packages.
    if {p.name for p in files} != {config.name, 'main.dart'}:
        raise ValueError(f'Unexpected non-package inputs: {files}')
    for name in ['rk-dart-build', 'rebuild.sh', 'README.md']:
        shutil.copyfile(here / name, output / name)
    for name in ['rk-dart-build', 'rebuild.sh']:
        (output / name).chmod(0o755)
    shutil.copyfile(here / 'main.dart.in', output / 'main.dart')
    shutil.copyfile(repo / 'doc/archive/native-assets-sdk.patch',
                    output / 'native-assets-sdk.patch')
    shutil.copyfile(sdk / 'DEPS', output / 'SDK-DEPS')
    (output / 'package_config.json').write_text(json.dumps(
        {'configVersion': 2, 'packages': mappings}, indent=2) + '\n')
    (output / 'PROVENANCE.json').write_text(json.dumps(
        {'sdkVersion': '3.13.5',
         'rebuildHosts': ['macos-arm64', 'linux-arm64', 'linux-x64'],
         'upstreamIssue': 'https://github.com/dart-lang/sdk/issues/64556',
         'packages': provenance}, indent=2) + '\n')
    (output / 'LICENSES.txt').write_text('\n\n'.join(
        f'===== {name} =====\n{text}' for name, text in notices))
    print(f'Exported {len(mappings)} packages to {output}; rebuild before shipping.')


if __name__ == '__main__':
    main()
