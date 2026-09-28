import 'dart:async';
import 'dart:io';

import 'package:fleury/fleury.dart';
import 'package:fleury/fleury_test_support.dart';
import 'package:rk/src/installations/model.dart';
import 'package:rk/src/installations/provider.dart';
import 'package:rk/src/tui/matrix.dart';
import 'package:rk/src/tui/use_picker.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

void main() {
  test('wide table is bounded; only the focused action is blue', () {
    final scratch = Directory.systemTemp.createTempSync('rk-table-layout-');
    addTearDown(() => scratch.deleteSync(recursive: true));
    final project = fixture(scratch);
    final states = [
      ProjectInstallations(
        project,
        {
          InstallationSource.local: SourceInspection(
            installation: Installation(
              source: InstallationSource.local,
              version: '1.0.0',
              location: project.directory,
              commands: const {},
            ),
          ),
          InstallationSource.pub: const SourceInspection(
            problem:
                'Already activated from a local path. To replace it with pub.dev, first run:\n'
                'dart pub global deactivate orbit_cli',
          ),
        },
        selected: InstallationSource.local,
        currentSources: {
          for (final c in project.commands) c: InstallationSource.local,
        },
      ),
    ];
    final model = UsePicker(
      states: states,
      refresh: () async => states,
      checkAvailable: (_, _, _) => Completer<AvailableInstallation>().future,
      downloadAvailable: (_, _, _, _) async => throw StateError('No downloads'),
      use: (_, _, _, _) async => throw StateError('No switches'),
      close: () {},
    );
    addTearDown(model.dispose);
    final tester = FleuryTester(viewportSize: const CellSize(240, 30));
    addTearDown(tester.dispose);
    tester.pumpWidget(
      FleuryApp(title: 'rk', theme: matrixTheme, home: UseScreen(model)),
    );
    tester.pump();
    final lines = tester.renderToString().split('\n');
    expect(lines.every((line) => line.trimRight().length <= 104), isTrue);
    expect(lines.join('\n'), contains('Already activated from a local path'));
    expect(lines.join('\n'), contains('dart pub global deactivate orbit_cli'));
    expect(lines.join('\n'), isNot(contains('Why?')));
    expect(lines.join('\n'), isNot(contains('↓ Download')));
    expect(lines.join('\n'), isNot(contains('Not installed')));
    final row = lines.indexWhere((line) => line.contains('This checkout'));
    void expectRow(Color color) {
      final buffer = tester.render();
      for (
        var col = 2;
        col < lines.firstWhere((line) => line.contains('─')).trimRight().length;
        col++
      ) {
        expect(
          buffer.atColRow(col, row).style.background,
          color,
          reason:
              'Cell $col must share the row background, including foreground content',
        );
      }
    }

    expectRow(const RgbColor(24, 55, 41));
    tester.sendMouse(
      MouseEvent(
        kind: MouseEventKind.moved,
        button: MouseButton.none,
        col: 45,
        row: row,
      ),
    );
    tester.pump();
    expectRow(const RgbColor(24, 55, 41));
    // The default badge is status, never a hoverable/focusable button.
    tester.sendMouse(
      MouseEvent(
        kind: MouseEventKind.moved,
        button: MouseButton.none,
        col: 95,
        row: row,
      ),
    );
    tester.pump();
    expectRow(const RgbColor(24, 55, 41));
    expect(lines[row], contains('✓ Default'));
    expect(lines[row], isNot(contains('[')));
    tester.sendKey(const KeyEvent(KeyCode.tab));
    tester.pump();
    expectRow(const RgbColor(24, 55, 41));
    tester.render(size: const CellSize(40, 12));
    tester.pump();
    expect(tester.renderToString(), contains('Esc Done'));
  });
}
