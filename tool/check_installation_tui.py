#!/usr/bin/env python3
"""Exercise RK's inline commands in disposable projects (macOS/Linux).

Install tool/tui-requirements.txt, then:
  python3 tool/check_installation_tui.py /absolute/path/to/compiled/rk
Dart must be on PATH. No personal installations or shell settings are changed.
A terminal emulator supplies cursor reports and checks actual visible content.
"""

import argparse
import codecs
import fcntl
import os
from pathlib import Path
import pty
import re
import select
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time

import pyte


class Terminal:
    def __init__(self, executable, command, project, home, *, cols=132, rows=32, arguments=(), environment=None):
        self.master, self.slave = pty.openpty()
        self.set_size(cols, rows)
        self.before = termios.tcgetattr(self.slave)
        self.blocking = os.get_blocking(self.slave)
        self.raw = b''
        self.decoder = codecs.getincrementaldecoder('utf-8')('replace')
        self.keyboard_tail = ''
        self.hold_replies = False
        self.held_replies = []
        owner = self

        class Screen(pyte.HistoryScreen):
            def write_process_input(self, data):
                if owner.hold_replies:
                    owner.held_replies.append(data.encode())
                else:
                    os.write(owner.master, data.encode())

        self.screen = Screen(cols, rows, history=2000)
        self.stream = pyte.Stream(self.screen)
        os.write(self.slave, f'Shell history stays here\r\n$ rk {command}\r\n'.encode())
        self.process = subprocess.Popen(
            [str(executable), command, *arguments], cwd=project,
            env={**{k: v for k, v in os.environ.items() if k not in ('NO_COLOR', 'FORCE_COLOR')},
                 'TERM': 'xterm-256color', 'COLORTERM': 'truecolor',
                 'SHELL': '/bin/sh', 'HOME': str(home), 'FLEURY_SYNC_OUTPUT': '0',
                 'PUB_CACHE': str(home / 'cache'), 'XDG_DATA_HOME': str(home / 'data'),
                 'XDG_CONFIG_HOME': str(home / 'config'), **(environment or {})},
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

    def set_size(self, cols, rows):
        fcntl.ioctl(self.master, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))

    def resize(self, cols, rows):
        # Apply bytes already written for the old size before changing the
        # emulator geometry. Otherwise an old-size row reservation is replayed
        # at the new height and the harness invents a scrollback-loss failure.
        while select.select([self.master], [], [], 0)[0]:
            self.read()
        y = max(0, self.screen.cursor.y - max(0, self.screen.lines - rows))
        self.screen.resize(lines=rows, columns=cols)
        self.screen.cursor.y = min(y, rows - 1)
        self.screen.cursor.x = min(self.screen.cursor.x, cols - 1)
        self.set_size(cols, rows)
        self.process.send_signal(signal.SIGWINCH)

    def text(self):
        return '\n'.join(self.screen.display)

    def read(self):
        if select.select([self.master], [], [], .1)[0]:
            chunk = os.read(self.master, 65536)
            self.raw += chunk
            text = self.keyboard_tail + self.decoder.decode(chunk)
            # pyte predates Kitty's keyboard stack. Ignore its unknown CSI
            # sequences, including ones split across reads, like a legacy host.
            tail = re.search(r'\x1b(?:\[(?:[<>?][0-9;]*)?)?$', text)
            self.keyboard_tail = tail[0] if tail else ''
            if tail:
                text = text[:tail.start()]
            self.stream.feed(re.sub(r'\x1b\[[<>?][0-9;]*u', '', text))

    def wait(self, text, timeout=30):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            self.read()
            if text in self.text():
                return
            if self.process.poll() is not None:
                while select.select([self.master], [], [], .1)[0]:
                    self.read()
                if text in self.text():
                    return
                break
        raise AssertionError(f'Missing {text!r}; exit={self.process.poll()}\n{self.text()}\n{self.raw[-2500:]!r}')

    def wait_layout(self, predicate, timeout=10):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline and self.process.poll() is None:
            self.read()
            if predicate(self.screen.display):
                return
        raise AssertionError(f'Layout did not settle after resize:\n{self.text()}')

    def send(self, keys):
        os.write(self.master, keys)
        time.sleep(.15)

    def click(self, text):
        self.wait(text)
        # Inline content measurement can move the footer after its first frame.
        # Click the settled target, not coordinates from a frame still resizing.
        deadline = time.monotonic() + 2
        stable_since = time.monotonic()
        previous = self.text()
        while time.monotonic() < deadline:
            self.read()
            current = self.text()
            if current != previous:
                stable_since = time.monotonic()
                previous = current
            elif time.monotonic() - stable_since >= .2:
                break
        row, line = next((i, line) for i, line in enumerate(self.screen.display) if text in line)
        col = line.index(text)
        self.send(f'\x1b[<0;{col+1};{row+1}M\x1b[<0;{col+1};{row+1}m'.encode())

    def finish(self, expected=0):
        deadline = time.monotonic() + 10
        while self.process.poll() is None and time.monotonic() < deadline:
            self.read()
        assert self.process.poll() == expected, (self.process.poll(), self.text())
        while select.select([self.master], [], [], .1)[0]:
            self.read()
        after = termios.tcgetattr(self.slave)
        if sys.platform == 'darwin':
            # Kernel-owned pending retype state is not an application mode.
            self.before[3] &= ~termios.PENDIN
            after[3] &= ~termios.PENDIN
        assert self.before == after, 'terminal modes not restored'
        assert self.blocking == os.get_blocking(self.slave), 'input blocking mode changed'
        assert b'\x1b[?1049' not in self.raw, 'entered the alternate screen'
        assert b'\x1b[2J' not in self.raw, 'cleared shell history'
        history = '\n'.join(''.join(cell.data for cell in line.values())
                            for line in self.screen.history.top) + self.text()
        assert 'Shell history stays here' in history, history
        for title in ['Choose where', 'Choose the outputs', 'Review release.toml',
                      'Install a source', 'Remove a source']:
            assert title not in self.text(), f'Inline frame survived exit: {self.text()}'
        assert b'\x1b[?25h' in self.raw, 'cursor hidden after exit'
        assert b'\x1b[?1006l' in self.raw, 'mouse capture left enabled'


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
        home = root / 'install'
        project = fixture(home, True)
        with Terminal(executable, 'install', project, home) as terminal:
            terminal.wait('Install a source.')
            terminal.send(b'\t\r')
            terminal.wait('installed from Local', timeout=60)
            terminal.finish()
        assert not (home / 'data/rk/bin/orbit').exists(), 'install changed routing'
        print('install: prepared without switching; inline restored', flush=True)
        with Terminal(executable, 'uninstall', project, home) as terminal:
            terminal.wait('Remove a source')
            terminal.send(b'\t\r')
            terminal.wait('Remove orbit from Local?')
            terminal.send(b'\x1b')
            terminal.wait('Remove a source')
            terminal.send(b'\r')  # Cancellation restores the originating cell.
            terminal.wait('Remove orbit from Local?')
            terminal.click('Remove installation')
            terminal.wait('removed from Local')
            terminal.finish()
        assert (project / 'bin/orbit.dart').exists(), 'local uninstall removed checkout'
        print('uninstall: confirmation, cancellation, removal; inline restored', flush=True)

        home = root / 'use'
        project = fixture(home, True)
        with Terminal(executable, 'use', project, home) as terminal:
            terminal.wait('Choose where your commands come from.')
            terminal.click('Install & use')
            terminal.wait('→ Local', timeout=60)
            terminal.finish()
            assert '→ Local' in terminal.text(), 'result not retained after exit'
        result = subprocess.check_output([str(home / 'data/rk/bin/orbit')], text=True)
        assert result.strip() == 'local dogfood'
        print('use: selected command runs; result retained; inline restored', flush=True)

        home = root / 'init'
        project = fixture(home, False)
        with Terminal(executable, 'init', project, home) as terminal:
            terminal.wait('Choose the outputs for each package.')
            terminal.click('Review configuration')
            terminal.wait('Review release.toml')
            assert not (project / 'release.toml').exists()
            terminal.send(b'\x1b')
            terminal.wait('Choose the outputs for each package.')
            terminal.click('Review configuration')
            terminal.wait('Review release.toml')
            terminal.click('Create release.toml')
            terminal.finish()
        assert (project / 'release.toml').exists()
        print('init: review, Back, create; inline restored', flush=True)

        for command in ['use', 'install', 'uninstall', 'init']:
            home = root / f'narrow-{command}'
            project = fixture(home, command != 'init')
            with Terminal(executable, command, project, home, cols=40, rows=18) as terminal:
                terminal.wait(f'rk {command}')
                terminal.wait('Esc')
                terminal.resize(90, 24)
                # Esc already exists in the old frame. Observe the new layout
                # for this flow; pending-resize exit is a separate regression.
                terminal.wait_layout(
                    (lambda lines: any('Binary' in line and 'Git tag' in line for line in lines))
                    if command == 'init' else
                    (lambda lines: any('PROJECT' in line for line in lines)))
                terminal.send(b'\x1b')
                terminal.finish()
            if command == 'init':
                assert not (project / 'release.toml').exists()
        print('all four commands: narrow layout, resize, Escape; inline restored', flush=True)

        for command in ['use', 'init']:
            for cause, expected in [('ctrl-c', 130), (signal.SIGINT, 130),
                                    (signal.SIGTERM, 143), (signal.SIGHUP, 129)]:
                home = root / f'{command}-{cause}'
                project = fixture(home, command != 'init')
                with Terminal(executable, command, project, home) as terminal:
                    terminal.wait('Esc')
                    if cause == 'ctrl-c':
                        terminal.send(b'\x03')
                    else:
                        terminal.process.send_signal(cause)
                    terminal.finish(expected)
                if command == 'init':
                    assert not (project / 'release.toml').exists()
        print('use/init: Ctrl+C and SIGINT/TERM/HUP preserve status; inline restored', flush=True)


if __name__ == '__main__':
    main()
