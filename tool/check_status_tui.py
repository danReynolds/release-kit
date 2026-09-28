#!/usr/bin/env python3
"""Read-only native status matrix checks using an empty local Git remote.

  python3 tool/check_status_tui.py /absolute/path/to/compiled/rk
Uses the same PTY/emulator as the installation suite. No network or user data.
"""
import argparse
from pathlib import Path
import subprocess
import tempfile
import time

from check_installation_tui import Terminal


def git(root, *args):
    subprocess.run(['git', '-C', str(root), *args], check=True, capture_output=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('executable', type=Path)
    executable = parser.parse_args().executable.resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix='rk-status-tui-') as temporary:
        home = Path(temporary)
        project = home / 'project'
        project.mkdir()
        for name, version in [('core', '0.4.0'), ('cli', '1.2.0')]:
            package = project / name
            package.mkdir()
            (package / 'pubspec.yaml').write_text(f'name: orbit_{name}\nversion: {version}\n')
            (package / 'CHANGELOG.md').write_text(f'## {version}\n\n- Example.\n')
        (project / 'release.toml').write_text('schema = 2\n' + ''.join(
            f'[release.{name}]\npath = "{name}"\ntag = "{name}-v{{version}}"\npublish = ["git-tag"]\n'
            for name in ['core', 'cli']))
        git(project, 'init', '-q')
        git(project, 'config', 'user.name', 'Status fixture')
        git(project, 'config', 'user.email', 'status@example.test')
        git(project, 'add', '.')
        git(project, 'commit', '-qm', 'Fixture')
        remote = home / 'remote.git'
        subprocess.run(['git', 'init', '--bare', '-q', str(remote)], check=True)
        git(project, 'remote', 'add', 'origin', str(remote))
        git(project, 'push', '-u', 'origin', 'HEAD')
        original = subprocess.check_output(['git', '-C', str(project), 'status', '--porcelain'])

        for width, color in [(132, True), (40, True), (104, False)]:
            env = {} if color else {'NO_COLOR': '1'}
            with Terminal(executable, 'status', project, home, cols=width, rows=24,
                          environment=env) as terminal:
                terminal.wait('checked at')
                terminal.wait('Not published')
                terminal.wait('Esc Done')
                assert b'42;76;108' not in terminal.raw, 'focus was shown on open'
                if width > 104:
                    assert all(not line[104:].strip() for line in terminal.screen.display), terminal.text()
                terminal.send(b'\x1b[B\x1b[C\r')
                terminal.wait('Candidate: 0.4.0')
                terminal.wait('Back')
                terminal.send(b'\x1b')
                terminal.wait('checked at')
                terminal.send(b'\r')
                terminal.wait('Candidate: 0.4.0')
                terminal.resize(40, 12)
                terminal.wait('Back')
                terminal.send(b'\x1b')
                terminal.wait('Esc Done')
                terminal.send(b'r')
                terminal.wait('checked at')
                terminal.send(b'\x1b')
                terminal.finish()
                if not color:
                    assert b'38;2;' not in terminal.raw and b'48;2;' not in terminal.raw
            print(f'status: {width} columns, color={color}, details/Back/refresh/resize/exit passed', flush=True)

        with Terminal(executable, None, project, home) as terminal:
            terminal.wait('checked at')
            terminal.wait('Esc Done')
            terminal.send(b'\x1b')
            terminal.finish()
        print('bare rk: opens the status matrix by default', flush=True)

        with Terminal(executable, 'status', project, home) as terminal:
            # The fake shell prompt also contains "rk status". Wait for an
            # actual UI frame before sending a raw-input Ctrl+C.
            terminal.wait('release destinations')
            started = time.monotonic()
            terminal.send(b'\x03')
            terminal.finish(130)
            assert time.monotonic() - started < 3, 'Ctrl+C waited on status checks'
        assert subprocess.check_output(['git', '-C', str(project), 'status', '--porcelain']) == original
        print('status: Ctrl+C restored terminal promptly; repository unchanged', flush=True)

        for args in [('status',), (), ('status', '--json'), ('--json',)]:
            result = subprocess.run([str(executable), *args], cwd=project, capture_output=True, text=True)
            assert result.returncode == 0, result.stderr + result.stdout
            assert '\x1b[' not in result.stdout, result.stdout
            if '--json' in args:
                import json
                assert json.loads(result.stdout)['exit'] == 0
        print('status: redirected and JSON paths stay finite and free of terminal escapes', flush=True)

        empty = home / 'empty'
        empty.mkdir()
        with Terminal(executable, 'status', empty, home) as terminal:
            terminal.finish()
            assert 'rk init' in terminal.text(), terminal.text()
        (empty / 'release.toml').write_text('schema = "broken"\n')
        with Terminal(executable, 'status', empty, home) as terminal:
            terminal.wait('Error details')
            terminal.activate('Error details')
            terminal.wait('Back')
            assert 'release.toml' in terminal.text(), terminal.text()
            terminal.send(b'\x1b')
            terminal.wait('Error details')
            terminal.send(b'\x1b')
            terminal.finish(1)
        print('status: missing setup exits with guidance; configuration errors expose full evidence', flush=True)


if __name__ == '__main__':
    main()
