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


def hover(terminal, text):
    row, col = locate(terminal, text)
    terminal.send(f'\x1b[<35;{col+1};{row+1}M'.encode())
    settle(terminal)
    return row, col


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


def workspace(home, configured=True):
    project = home / 'project'
    for name in ['orbit', 'orbit_admin']:
        package = project / name
        (package / 'bin').mkdir(parents=True)
        (package / 'pubspec.yaml').write_text(
            f'name: {name}\nversion: 1.0.0\nenvironment:\n  sdk: ^3.10.4\n'
            f'executables:\n  {name}: main\n')
        (package / 'bin/main.dart').write_text(f"void main() => print('{name}');\n")
    if not configured:
        (project / 'pubspec.yaml').write_text(
            'name: orbit_workspace\npublish_to: none\nenvironment:\n  sdk: ^3.10.4\n'
            'workspace:\n  - orbit\n  - orbit_admin\n')
    if configured:
        (project / 'release.toml').write_text(
            'schema = 2\n[release.apps]\npublish = []\n'
            '[[release.apps.project]]\npath = "orbit"\npublish = ["pub.dev"]\n'
            '[[release.apps.project]]\npath = "orbit_admin"\npublish = ["pub.dev"]\n')
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
        with Terminal(executable, 'use', project, home) as terminal:
            terminal.wait('Esc Cancel')
            settle(terminal)
            row, col = locate(terminal, '✓ Selected')
            selected = terminal.screen.buffer[row][col]
            assert selected.bg == '2a4c6c', selected  # initial focus is the active source
            assert sum(line[:25].strip() == 'orbit' for line in terminal.screen.display) == 1
            assert 'Commands: orbit' not in terminal.text()
            assert all(terminal.screen.buffer[y][0].bg == 'default' for y in range(32))
            assert next(i for i, line in enumerate(terminal.screen.display) if 'Esc Cancel' in line) < 17
            shot(terminal, 'use-current')
            hover_row, hover_col = hover(terminal, 'Unavailable')
            active = terminal.screen.buffer[row][col]
            hovered = terminal.screen.buffer[hover_row][hover_col]
            assert active.bg == '183729', active  # active selection retains its green tint
            assert hovered.bg == selected.bg and not hovered.underscore, hovered
            assert terminal.process.poll() is None, 'hover activated an option'
            shot(terminal, 'use-hover')
            terminal.send(b'\x1b[D')
            settle(terminal)
            assert terminal.screen.buffer[row][col].bg == selected.bg
            assert terminal.screen.buffer[hover_row][hover_col].bg == 'default', 'stale hover retained a second highlight'
            terminal.click('Unavailable')
            terminal.wait('Repair it with dart pub global activate')
            settle(terminal)
            assert terminal.process.poll() is None, 'an unavailable option closed the picker'
            shot(terminal, 'use-unavailable')
            terminal.send(b'\x1b')
            terminal.finish(1)  # a refused operation remains nonzero when dismissed
        print('PASS active/hover/keyboard states, compact height, no duplicate command, unavailable reason', flush=True)

        with Terminal(executable, 'use', project, home, environment={'NO_COLOR': '1'}) as terminal:
            terminal.wait('Esc Cancel')
            settle(terminal)
            row, col = locate(terminal, '✓ Selected')
            assert terminal.screen.buffer[row][col].reverse, 'NO_COLOR lost focus'
            hover_row, hover_col = hover(terminal, 'Unavailable')
            assert terminal.screen.buffer[hover_row][hover_col].reverse
            assert not terminal.screen.buffer[row][col].reverse
            terminal.send(b'\x1b')
            terminal.finish()
        print('PASS NO_COLOR preserves navigation and selected checkmarks', flush=True)

        home = root / 'many'
        project = workspace(home)
        with Terminal(executable, 'use', project, home) as terminal:
            terminal.wait('2 projects')
            terminal.click('Install & use')
            terminal.wait('orbit → Local')
            settle(terminal)
            assert terminal.process.poll() is None, 'multi-project use closed after one row'
            row, col = locate(terminal, '✓ Selected')
            assert terminal.screen.buffer[row][col].bg == '2a4c6c', 'operation lost keyboard focus'
            shot(terminal, 'use-multiple')
            # The remaining uninstalled Local cell belongs to the second row.
            rows = [(i, line) for i, line in enumerate(terminal.screen.display)
                    if 'orbit_admin' in line and 'Install & use' in line]
            assert rows, terminal.text()
            row, line = rows[0]
            col = line.index('Install & use')
            terminal.send(f'\x1b[<0;{col+1};{row+1}M\x1b[<0;{col+1};{row+1}m'.encode())
            terminal.wait('orbit_admin → Local')
            assert terminal.process.poll() is None
            terminal.click('Esc Done')
            terminal.finish()
        assert 'orbit\n' == subprocess.check_output([str(home / 'data/rk/bin/orbit')], text=True)
        assert 'orbit_admin\n' == subprocess.check_output([str(home / 'data/rk/bin/orbit_admin')], text=True)
        # Restricting a multi-project configuration to one row restores auto-close.
        with Terminal(executable, 'use', project, home, arguments=('-p', 'orbit')) as terminal:
            terminal.wait('1 project')
            terminal.send(b'\r')
            terminal.finish()
        print('PASS multi-project stays open; explicit -p completes in one selection', flush=True)

        home = root / 'install-review'
        project = fixture(home, True)
        with Terminal(executable, 'install', project, home) as terminal:
            terminal.wait('Esc Cancel')
            settle(terminal)
            shot(terminal, 'install')
            terminal.send(b'\r')
            terminal.finish()
        with Terminal(executable, 'uninstall', project, home) as terminal:
            terminal.wait('Remove a source')
            settle(terminal)
            shot(terminal, 'uninstall')
            terminal.send(b'\r')
            terminal.wait('Remove orbit from Local?')
            settle(terminal)
            shot(terminal, 'uninstall-confirm')
            terminal.click('Remove installation')
            terminal.finish()
        with Terminal(executable, 'uninstall', project, home) as terminal:
            terminal.wait('Not installed')
            settle(terminal)
            row, col = locate(terminal, 'Esc Cancel')
            assert terminal.screen.buffer[row][col].bg == '2a4c6c', 'empty uninstall must focus its exit'
            terminal.send(b'\r')
            terminal.finish()
        print('PASS install/uninstall states and empty uninstall exit focus', flush=True)

        home = root / 'partial'
        project = workspace(home)
        run(executable, project, home, 'install', 'local', '-p', 'orbit_admin', '--json')
        with Terminal(executable, 'uninstall', project, home) as terminal:
            terminal.wait('Remove a source')
            settle(terminal)
            terminal.send(b'\r')
            terminal.wait('Remove orbit_admin from Local?')
            terminal.click('Remove installation')
            terminal.wait('removed from Local')
            terminal.click('Esc Done')
            terminal.finish()
        print('PASS uninstall starts on a usable row when the first project has no installations', flush=True)

        home = root / 'init'
        project = workspace(home, configured=False)
        with Terminal(executable, 'init', project, home) as terminal:
            terminal.wait('Review configuration')
            settle(terminal)
            shot(terminal, 'init-multiple')
            hover(terminal, 'Review configuration')
            terminal.send(b'\r')
            terminal.wait('Review release.toml')
            settle(terminal)
            shot(terminal, 'init-review')
            terminal.send(b'\x1b')
            terminal.wait('Choose the outputs')
            terminal.click('Review configuration')
            terminal.wait('Review release.toml')
            terminal.click('Create release.toml')
            terminal.finish()
        assert (project / 'release.toml').exists()
        print('PASS init shares hover/keyboard behavior and review/Back/Create', flush=True)

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
                    terminal.send(b' ')
                    terminal.wait('✓ Added')
                    assert 'Local build' in terminal.text(), 'feedback pushed the focused choice offscreen'
                    shot(terminal, 'init-short-toggled')
                    terminal.click('Review configuration')
                    terminal.wait('Review release.toml')
                    terminal.click('Create release.toml')
                elif command == 'uninstall':
                    terminal.send(b'\r')
                    terminal.wait('Remove installation')
                    terminal.click('Remove installation')
                else:
                    terminal.send(b'\r')
                terminal.finish()
        print('PASS all four commands complete at 40×12 with actions reachable', flush=True)


if __name__ == '__main__':
    main()
