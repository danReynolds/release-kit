#!/usr/bin/env python3
"""Check that status prints a durable report and exits without terminal input.

  python3 tool/check_status_cli.py /absolute/path/to/compiled/rk
Uses disposable repositories and an empty local Git remote; no network or user data.
"""
import argparse
import json
import os
from pathlib import Path
import re
import select
import subprocess
import sys
import tempfile
import termios
import time

from check_installation_tui import Terminal


def git(root, *args):
    subprocess.run(['git', '-C', str(root), *args], check=True, capture_output=True)


def report(terminal, expected=0):
    # Deliberately send no keys or clicks: a status report must finish by itself.
    deadline = time.monotonic() + 30
    while terminal.process.poll() is None and time.monotonic() < deadline:
        terminal.read()
    assert terminal.process.poll() == expected, (terminal.process.poll(), terminal.text())
    while select.select([terminal.master], [], [], .1)[0]:
        terminal.read()
    after = termios.tcgetattr(terminal.slave)
    before = terminal.before.copy()
    if sys.platform == 'darwin':
        before[3] &= ~termios.PENDIN
        after[3] &= ~termios.PENDIN
    assert before == after, 'status changed terminal input modes'
    assert terminal.blocking == os.get_blocking(terminal.slave), 'status changed input blocking'
    assert not re.search(rb'\x1b\[\?(?:1000|1002|1003|1006|1049)h', terminal.raw)
    assert b'\x1b[6n' not in terminal.raw, 'status reserved an inline region'
    assert b'\x1b[2J' not in terminal.raw, 'status erased shell history'
    if b'\x1b[?25l' in terminal.raw:
        assert terminal.raw.rfind(b'\x1b[?25h') > terminal.raw.rfind(b'\x1b[?25l')
    text = terminal.text()
    assert 'Shell history stays here' in text
    assert 'Esc Done' not in text and 'Refresh' not in text
    return text


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('executable', type=Path)
    executable = parser.parse_args().executable.resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix='rk-status-cli-') as temporary:
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

        for command in ['status', None]:
            for width, color in [(132, True), (40, True), (104, False)]:
                env = {} if color else {'NO_COLOR': '1'}
                with Terminal(executable, command, project, home, cols=width, rows=60,
                              environment=env) as terminal:
                    text = report(terminal)
                    for expected in ['0.4.0', '1.2.0', 'Git tag', 'Not published']:
                        assert expected in text, text
                    if not color:
                        assert not re.search(rb'\x1b\[[0-9;]*m', terminal.raw)
            print(f'{command or "bare rk"}: report retained; exits without input at wide/narrow/NO_COLOR', flush=True)

        with Terminal(executable, 'status', project, home, rows=60, arguments=('cli',)) as terminal:
            text = report(terminal)
            assert '1.2.0' in text and '0.4.0' not in text, text
            assert 'rk release cli --stage' in text, text
        with Terminal(executable, 'status', project, home, rows=60, arguments=('missing',)) as terminal:
            assert 'no unit' in report(terminal, 2).lower()
        print('status: unit filtering, next action and invalid-unit exit remain intact', flush=True)

        for args in [('status',), (), ('status', '--json'), ('--json',)]:
            result = subprocess.run([str(executable), *args], cwd=project, capture_output=True, text=True, timeout=30)
            assert result.returncode == 0, result.stderr + result.stdout
            assert '\x1b[' not in result.stdout, result.stdout
            if '--json' in args:
                assert json.loads(result.stdout)['exit'] == 0
        print('status: redirected and JSON reports remain finite and escape-free', flush=True)

        empty = home / 'empty'
        empty.mkdir()
        with Terminal(executable, 'status', empty, home, rows=60) as terminal:
            assert 'rk init' in report(terminal)
        (empty / 'release.toml').write_text('schema = "broken"\n')
        with Terminal(executable, 'status', empty, home, rows=60) as terminal:
            assert 'release.toml' in report(terminal, 1)
        assert subprocess.check_output(['git', '-C', str(project), 'status', '--porcelain']) == original
        print('status: missing/invalid setup exits with guidance; repository unchanged', flush=True)


if __name__ == '__main__':
    main()
