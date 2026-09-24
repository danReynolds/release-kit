#!/usr/bin/env python3
"""Exercise real RK terminal sessions in disposable projects (macOS/Linux).

Usage: python3 tool/check_installation_tui.py /absolute/path/to/compiled/rk
Dart must be on PATH. No personal installations or shell settings are changed.
"""

import argparse
import fcntl
import os
from pathlib import Path
import pty
import re
import select
import struct
import subprocess
import tempfile
import termios
import time


class Terminal:
    def __init__(self, executable, command, project, home):
        self.master, self.slave = pty.openpty()
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack('HHHH', 30, 132, 0, 0))
        self.before = termios.tcgetattr(self.slave)
        self.raw = b''
        self.process = subprocess.Popen(
            [str(executable), command], cwd=project,
            env={**os.environ, 'TERM': 'xterm-256color', 'COLORTERM': 'truecolor',
                 'SHELL': '/bin/sh', 'HOME': str(home),
                 'PUB_CACHE': str(home / 'cache'), 'XDG_DATA_HOME': str(home / 'data')},
            stdin=self.slave, stdout=self.slave, stderr=self.slave,
        )

    def __enter__(self):
        return self

    def __exit__(self, *_):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        os.close(self.master)
        os.close(self.slave)

    def text(self):
        return re.sub(r'\x1b\[[0-9;:?<>]*[ -/]*[@-~]', '', self.raw.decode(errors='replace'))

    def read(self):
        if select.select([self.master], [], [], .1)[0]:
            chunk = os.read(self.master, 65536)
            self.raw += chunk
            if b'\x1b[6n' in chunk:
                os.write(self.master, b'\x1b[1;1R')
            if b'\x1b[c' in chunk:
                os.write(self.master, b'\x1b[?1;2c')

    def wait(self, text, timeout=30):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if text in self.text():
                return
            self.read()
            if self.process.poll() is not None:
                break
        raise AssertionError(f'Missing {text!r}\n{self.text()[-2500:]}')

    def send(self, keys):
        os.write(self.master, keys)
        time.sleep(.15)

    def finish(self):
        deadline = time.monotonic() + 10
        while self.process.poll() is None and time.monotonic() < deadline:
            self.read()
        assert self.process.poll() == 0, self.text()[-2500:]
        while select.select([self.master], [], [], .1)[0]:
            self.read()
        after = termios.tcgetattr(self.slave)
        mask = termios.ECHO | termios.ICANON
        assert self.before[3] & mask == after[3] & mask, 'terminal modes not restored'
        assert b'\x1b[?1049l' in self.raw, 'alternate screen not restored'


def fixture(home, configured):
    project = home / 'project'
    (project / 'bin').mkdir(parents=True)
    (project / 'pubspec.yaml').write_text(
        'name: rk_dogfood\nversion: 1.0.0\nenvironment:\n  sdk: ^3.10.4\n'
        'executables:\n  orbit: orbit\n')
    (project / 'bin/orbit.dart').write_text("void main() { print('local dogfood'); }\n")
    if configured:
        (project / 'release.toml').write_text(
            'schema = 2\n[release.demo]\npublish = ["pub.dev"]\n')
    return project


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('executable', type=Path)
    executable = parser.parse_args().executable.resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix='rk-native-tui-') as temporary:
        root = Path(temporary).resolve()
        home = root / 'use'
        project = fixture(home, True)
        with Terminal(executable, 'use', project, home) as terminal:
            terminal.wait('Choose where your commands come from.')
            terminal.send(b'\r')
            terminal.wait('now selects Local', timeout=60)
            terminal.send(b'\x1b')
            terminal.finish()
        result = subprocess.check_output([str(home / 'data/rk/bin/orbit')], text=True)
        assert result.strip() == 'local dogfood'
        print('use: selected command runs; terminal restored', flush=True)

        home = root / 'init'
        project = fixture(home, False)
        with Terminal(executable, 'init', project, home) as terminal:
            terminal.wait('Choose the outputs for each package.')
            # Reading order includes the scroll viewport before its first cell.
            terminal.send(b'\x1b[Z')
            terminal.send(b'\x1b[Z')
            terminal.send(b'\r')
            terminal.wait('Review release.toml')
            assert not (project / 'release.toml').exists()
            terminal.send(b'\t')
            terminal.send(b'\r')
            terminal.finish()
        assert (project / 'release.toml').exists()
        print('init: reviewed before writing; terminal restored', flush=True)


if __name__ == '__main__':
    main()
