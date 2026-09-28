#!/usr/bin/env python3
"""Dogfood visible matrix states, compact sizing, and multi-project flows.
Uses disposable homes and only mutates local fixture registrations.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

from check_installation_tui import Terminal, fixture


def settle(terminal):
    deadline = time.monotonic() + .6
    while time.monotonic() < deadline:
        terminal.read()


def locate(terminal, text):
    terminal.wait(text)
    settle(terminal)
    row, line = next((i, line) for i, line in enumerate(terminal.screen.display) if text in line)
    return row, line.index(text)


def snapshot(terminal, path):
    if path is None:
        return
    path.write_text(json.dumps({
        'cols': terminal.screen.columns,
        'rows': terminal.screen.lines,
        'cells': [[terminal.screen.buffer[y][x]._asdict()
                   for x in range(terminal.screen.columns)]
                  for y in range(terminal.screen.lines)],
    }))


def env(home):
    return {**os.environ, 'HOME': str(home), 'SHELL': '/bin/sh',
            'PUB_CACHE': str(home / 'cache'), 'XDG_DATA_HOME': str(home / 'data'),
            'XDG_CONFIG_HOME': str(home / 'config')}


def run(executable, project, home, *args):
    result = subprocess.run([str(executable), *args], cwd=project, env=env(home),
                            capture_output=True, text=True, timeout=60)
    assert result.returncode == 0, result.stderr + result.stdout
    return result.stdout


def workspace(home, configured=True, names=('orbit', 'orbit_admin')):
    project = home / 'project'
    for name in names:
        package = project / name
        (package / 'bin').mkdir(parents=True, exist_ok=True)
        (package / 'pubspec.yaml').write_text(
            f'name: {name}\nversion: 1.0.0\nenvironment:\n  sdk: ^3.10.4\n'
            f'executables:\n  {name}: main\n')
        (package / 'bin/main.dart').write_text(f"void main() => print('{name}');\n")
    if not configured:
        (project / 'pubspec.yaml').write_text(
            'name: orbit_workspace\npublish_to: none\nenvironment:\n  sdk: ^3.10.4\n'
            'workspace:\n' + ''.join(f'  - {name}\n' for name in names))
    if configured:
        (project / 'release.toml').write_text(
            'schema = 2\n[release.apps]\npublish = []\n'
            + ''.join(f'[[release.apps.project]]\npath = "{name}"\npublish = ["pub.dev"]\n' for name in names))
    return project


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('executable', type=Path)
    parser.add_argument('--snapshots', type=Path)
    args = parser.parse_args()
    executable = args.executable.resolve(strict=True)
    if args.snapshots:
        args.snapshots.mkdir(parents=True, exist_ok=True)
    def shot(terminal, name):
        snapshot(terminal, args.snapshots / f'{name}.json' if args.snapshots else None)

    with tempfile.TemporaryDirectory(prefix='rk-ux-') as directory:
        root = Path(directory).resolve()
        home = root / 'states'
        project = fixture(home, True)
        # Same package/command name demonstrates that no duplicate line appears.
        manifest = project / 'pubspec.yaml'
        manifest.write_text(manifest.read_text().replace('rk_dogfood', 'orbit'))
        run(executable, project, home, 'use', 'local', '--json')
        # An incomplete Pub activation gives an inspectable unavailable choice.
        (home / 'cache/global_packages/orbit').mkdir(parents=True)
        with Terminal(executable, 'use', project, home, cols=240) as terminal:
            terminal.wait('Esc Done')
            settle(terminal)
            row, col = locate(terminal, 'Use     ]')
            selected = terminal.screen.buffer[row][col]
            assert selected.bg == 'default', selected  # saved selection is not the effective PATH default
            assert 'Selected' in terminal.text()
            assert not any(cell.bg == '2a4c6c' for line in terminal.screen.buffer.values()
                           for cell in line.values()), 'opening must have no focus'
            terminal.send(b'\r')
            settle(terminal)
            assert terminal.process.poll() is None, 'unfocused Enter activated a source'
            assert 'Preparing' not in terminal.text()
            assert sum('rk use' in line and 'orbit' in line for line in terminal.screen.display) == 1
            assert 'Commands: orbit' not in terminal.text()
            assert all(terminal.screen.buffer[y][0].bg == 'default' for y in range(32))
            assert next(i for i, line in enumerate(terminal.screen.display) if 'Esc Done' in line) < 24
            assert all(len(line.rstrip()) <= 104 for line in terminal.screen.display), 'table expanded beyond its content width'
            assert 'The Pub activation is incomplete.' in terminal.text(), 'problem must be visible without opening details'
            assert 'Why?' not in terminal.text()
            terminal.focus('Use     ]')
            assert terminal.screen.buffer[row][col].bg == '2a4c6c'
            name_row, name_col = locate(terminal, 'This checkout')
            assert terminal.screen.buffer[name_row][name_col].bg == 'default', 'focus recolored the source row'
            shot(terminal, 'use-action-focus')
            terminal.send(b'\t')  # Blocked Pub is skipped; focus reaches Refresh.
            settle(terminal)
            assert terminal.screen.buffer[row][col].bg == 'default'
            refresh_row, refresh_col = locate(terminal, 'r Refresh')
            assert terminal.screen.buffer[refresh_row][refresh_col].bg == '2a4c6c'
            shot(terminal, 'use-unavailable')
            terminal.send(b'\x1b')
            terminal.finish()
        print('PASS keyboard focus, no initial focus, width bound, inline unavailable reason', flush=True)

        with Terminal(executable, 'use', project, home, environment={'NO_COLOR': '1'}) as terminal:
            terminal.wait('Esc Done')
            settle(terminal)
            row, col = locate(terminal, 'Use     ]')
            assert not terminal.screen.buffer[row][col].reverse, 'NO_COLOR opened focused'
            terminal.send(b'\t')
            settle(terminal)
            assert terminal.screen.buffer[row][col].reverse, 'Tab did not focus the first action'
            name_row, name_col = locate(terminal, 'This checkout')
            assert not terminal.screen.buffer[name_row][name_col].reverse
            terminal.focus('r Refresh')
            refresh_row, refresh_col = locate(terminal, 'r Refresh')
            assert terminal.screen.buffer[refresh_row][refresh_col].reverse
            assert not terminal.screen.buffer[row][col].reverse
            terminal.send(b'\x1b')
            terminal.finish()
        print('PASS NO_COLOR focuses only the action and preserves selected checkmarks', flush=True)

        with Terminal(executable, 'use', project, home, cols=40, rows=12) as terminal:
            terminal.wait('Esc Done')
            terminal.send(b'\t\x1b[B')  # Blocked Pub has no action to navigate to.
            settle(terminal)
            row, col = locate(terminal, 'Use     ]')
            assert terminal.screen.buffer[row][col].bg == '2a4c6c'
            shot(terminal, 'use-compact-action')
            terminal.send(b'\x03')
            terminal.finish(130)
        print('PASS compact action navigation skips unavailable controls and restores on Ctrl+C', flush=True)

        home = root / 'many'
        project = workspace(home)
        with Terminal(executable, 'use', project, home) as terminal:
            terminal.wait('2 projects')
            terminal.activate('Use     ]')
            terminal.wait('orbit → Local')
            settle(terminal)
            assert terminal.process.poll() is None, 'multi-project use closed after one row'
            row, col = locate(terminal, 'Use     ]')
            terminal.focus('Use     ]')
            shot(terminal, 'use-multiple')
            # Row navigation reaches the second project's Local source,
            # even when the table needs to scroll at this terminal height.
            terminal.wait('Check failed')  # Retry is an explicit, focusable action.
            terminal.send(b'\x1b[B\x1b[B\r')
            terminal.wait('orbit_admin → Local')
            assert terminal.process.poll() is None
            terminal.activate('Esc Done')
            terminal.finish()
        assert 'orbit\n' == subprocess.check_output([str(home / 'data/rk/bin/orbit')], text=True)
        assert 'orbit_admin\n' == subprocess.check_output([str(home / 'data/rk/bin/orbit_admin')], text=True)
        # Restricting a multi-project configuration to one row restores auto-close.
        with Terminal(executable, 'use', project, home, arguments=('-p', 'orbit')) as terminal:
            terminal.wait('Choose what runs locally.')
            terminal.send(b'\t\r')
            terminal.finish()
        print('PASS multi-project stays open; explicit -p completes in one selection', flush=True)

        home = root / 'install-review'
        project = fixture(home, True)
        with Terminal(executable, 'install', project, home) as terminal:
            terminal.wait('Esc Cancel')
            settle(terminal)
            shot(terminal, 'install')
            terminal.send(b'\x1b[B\r')
            terminal.finish()
        with Terminal(executable, 'uninstall', project, home) as terminal:
            terminal.wait('Remove a source')
            settle(terminal)
            shot(terminal, 'uninstall')
            terminal.send(b'\t\r')
            terminal.wait('Remove orbit from Local?')
            settle(terminal)
            shot(terminal, 'uninstall-confirm')
            terminal.activate('Remove installation')
            terminal.finish()
        with Terminal(executable, 'uninstall', project, home) as terminal:
            terminal.wait('Not installed')
            settle(terminal)
            row, col = locate(terminal, 'Esc Cancel')
            assert terminal.screen.buffer[row][col].bg == 'default', 'empty uninstall opened focused'
            terminal.send(b'\t')
            settle(terminal)
            assert terminal.screen.buffer[row][col].bg == '2a4c6c', 'Tab did not reach the exit'
            terminal.send(b'\r')
            terminal.finish()
        print('PASS install/uninstall states and empty uninstall keyboard entry', flush=True)

        home = root / 'partial'
        project = workspace(home)
        run(executable, project, home, 'install', 'local', '-p', 'orbit_admin', '--json')
        with Terminal(executable, 'uninstall', project, home) as terminal:
            terminal.wait('Remove a source')
            settle(terminal)
            terminal.send(b'\t\r')
            terminal.wait('Remove orbit_admin from Local?')
            terminal.activate('Remove installation')
            terminal.wait('removed from Local')
            terminal.activate('Esc Done')
            terminal.finish()
        print('PASS uninstall navigation starts on a usable row when the first project has no installations', flush=True)

        names = [f'app_{i}' for i in range(10)]
        home = root / 'long-workspace'
        project = workspace(home, names=names)
        for name in (names[0], names[-1]):
            run(executable, project, home, 'install', 'local', '-p', name, '--json')
        with Terminal(executable, 'uninstall', project, home, cols=90, rows=18) as terminal:
            terminal.wait('Esc Done')
            terminal.send(b'\t\t\r')
            terminal.wait('Remove app_9')
            terminal.send(b'\x1b')
            terminal.wait('Remove a source')
            terminal.wait('app_9')
            shot(terminal, 'uninstall-return')
            terminal.send(b'\r')
            terminal.wait('Remove app_9')
            terminal.send(b'\x03')
            terminal.finish(130)
        (project / 'release.toml').unlink()
        project = workspace(home, configured=False, names=names)
        with Terminal(executable, 'init', project, home) as terminal:
            terminal.wait('Review configuration')
            terminal.activate('Review configuration')
            terminal.wait('More below')
            terminal.send(b'\x1b[F')
            terminal.wait('app_9')
            terminal.wait('End · PgUp/PgDn')
            shot(terminal, 'init-long-review')
            terminal.send(b'\r')  # Back stays focused while paging.
            terminal.wait('Choose the outputs')
            terminal.send(b'\x1b')
            terminal.finish()
        print('PASS long-workspace confirmation return and pageable configuration review', flush=True)

        # Spy on a provider at the CLI boundary. Closing an idle picker must
        # not start a second inspection, irrespective of subprocess speed.
        home = root / 'idle-close'
        project = fixture(home, True)
        (project / 'release.toml').write_text(
            'schema = 2\n[release.demo]\n'
            'publish = ["git-tag", "github-release", "homebrew"]\n'
            'binary_platforms = ["macos-arm64", "linux-x64"]\n')
        subprocess.run(['git', 'init', '-q'], cwd=project, check=True)
        subprocess.run(['git', 'remote', 'add', 'origin',
                        'https://github.com/example/orbit.git'], cwd=project, check=True)
        tools = home / 'tools'
        tools.mkdir()
        calls = home / 'brew-calls'
        brew = tools / 'brew'
        brew.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$RK_BREW_CALLS"\n')
        brew.chmod(0o755)
        with Terminal(executable, 'use', project, home,
                      environment={'PATH': str(tools) + ':' + os.environ['PATH'],
                                   'RK_BREW_CALLS': str(calls)}) as terminal:
            terminal.wait('Esc Done')
            before = calls.read_text()
            terminal.send(b'\x03')
            terminal.finish(130)
            assert calls.read_text() == before, 'Ctrl+C rescanned providers'
            assert before.splitlines() == ['list --formula --full-name -1'], before
        print('PASS Ctrl+C returns without another provider inspection', flush=True)

        home = root / 'init'
        project = workspace(home, configured=False)
        with Terminal(executable, 'init', project, home) as terminal:
            terminal.wait('Review configuration')
            settle(terminal)
            shot(terminal, 'init-multiple')
            terminal.focus('Review configuration')
            terminal.send(b'\r')
            terminal.wait('Review release.toml')
            settle(terminal)
            shot(terminal, 'init-review')
            terminal.send(b'\x1b')
            terminal.wait('Choose the outputs')
            terminal.activate('Review configuration')
            terminal.wait('Review release.toml')
            terminal.activate('Create release.toml')
            terminal.finish()
        assert (project / 'release.toml').exists()
        print('PASS init shares keyboard behavior and review/Back/Create', flush=True)

        for command in ['use', 'install', 'uninstall', 'init']:
            home = root / f'short-{command}'
            project = fixture(home, command != 'init')
            if command == 'uninstall':
                run(executable, project, home, 'install', 'local', '--json')
            with Terminal(executable, command, project, home, cols=40, rows=12) as terminal:
                terminal.wait('Esc')
                settle(terminal)
                shot(terminal, f'{command}-short')
                if command == 'init':
                    assert 'Local build' in terminal.text(), 'footer crowded out init choices'
                    terminal.send(b'\t ')
                    terminal.wait('✓ Added')
                    assert 'Local build' in terminal.text(), 'feedback pushed the focused choice offscreen'
                    shot(terminal, 'init-short-toggled')
                    terminal.activate('Review configuration')
                    terminal.wait('Review release.toml')
                    terminal.activate('Create release.toml')
                elif command == 'uninstall':
                    terminal.send(b'\t\r')
                    terminal.wait('Remove installation')
                    terminal.activate('Remove installation')
                else:
                    terminal.send(b'\t\r')
                terminal.finish()
        print('PASS all four commands complete at 40×12 with actions reachable', flush=True)

        for command in ['use', 'init']:
            home = root / f'resize-exit-{command}'
            project = fixture(home, command != 'init')
            with Terminal(executable, command, project, home, rows=24) as terminal:
                terminal.wait('Esc')
                settle(terminal)
                terminal.hold_replies = True
                start = len(terminal.raw)
                terminal.resize(90, 24)
                terminal.wait_layout(lambda _: b'\x1b[6n' in terminal.raw[start:])
                terminal.send(b'\x1b')
                terminal.hold_replies = False
                for reply in terminal.held_replies:
                    os.write(terminal.master, reply)
                terminal.held_replies.clear()
                terminal.finish()
        print('PASS use/init exit during a pending resize clears the old region', flush=True)


if __name__ == '__main__':
    main()
