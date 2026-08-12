import 'dart:math';

import '../engine/init_plan.dart';

/// The small terminal surface used by the init selector.
///
/// Keeping raw-mode ownership here makes restoration testable without a real
/// TTY. The composition root only adapts stdin/stdout and SIGINT.
abstract interface class InitTerminal {
  bool get lineMode;
  set lineMode(bool value);

  bool get echoMode;
  set echoMode(bool value);

  bool get echoNewlineMode;
  set echoNewlineMode(bool value);

  int get width;
  int get height;
  int readByte();
  void write(String value);
  Future<void> flush();
}

enum InitSelectorKey { up, down, left, right, toggle, review, cancel, ignore }

enum InitSelectorAction { changed, review, cancel, ignored }

final class InitSelectorResult {
  const InitSelectorResult(this.action, this.message);
  final InitSelectorAction action;
  final String message;
}

/// Pure state and rendering for the compact `rk init` matrix.
final class InitSelector {
  InitSelector(this.plan)
      : row = 0,
        column = 0,
        message = '';

  InitPlan plan;
  int row;
  int column;
  String message;

  InitOption get option => InitOption.values[column];
  InitCandidate get candidate => plan.candidates[row];

  InitSelectorResult handle(InitSelectorKey key) {
    if (plan.candidates.isEmpty) {
      return const InitSelectorResult(
        InitSelectorAction.cancel,
        'nothing discovered',
      );
    }
    switch (key) {
      case InitSelectorKey.up:
        row = (row - 1) % plan.candidates.length;
        break;
      case InitSelectorKey.down:
        row = (row + 1) % plan.candidates.length;
        break;
      case InitSelectorKey.left:
        column = (column - 1) % InitOption.values.length;
        break;
      case InitSelectorKey.right:
        column = (column + 1) % InitOption.values.length;
        break;
      case InitSelectorKey.toggle:
        final toggled = plan.toggle(row, option);
        plan = toggled.plan;
        message = toggled.message;
        return InitSelectorResult(InitSelectorAction.changed, message);
      case InitSelectorKey.review:
        return const InitSelectorResult(InitSelectorAction.review, '');
      case InitSelectorKey.cancel:
        return const InitSelectorResult(InitSelectorAction.cancel, '');
      case InitSelectorKey.ignore:
        return const InitSelectorResult(InitSelectorAction.ignored, '');
    }
    message = '';
    return const InitSelectorResult(InitSelectorAction.changed, '');
  }

  String render(int width, {int height = 24}) =>
      width >= 94 ? _matrix(height) : _card();

  String _matrix(int height) {
    const nameWidth = 24;
    final visibleRows = min(plan.candidates.length, max(3, height - 10));
    final start = min(
      max(0, row - visibleRows ~/ 2),
      max(0, plan.candidates.length - visibleRows),
    );
    final end = min(plan.candidates.length, start + visibleRows);
    final buffer = StringBuffer()
      ..writeln('Select release outputs'
          '${visibleRows < plan.candidates.length ? ' · ${row + 1}/${plan.candidates.length}' : ''}')
      ..writeln()
      ..writeln('                         Produce              Publish')
      ..writeln('  Use  Unit${' ' * (nameWidth - 4)}'
          'Binary   Git tag   pub.dev   GitHub   Homebrew');
    for (var index = start; index < end; index++) {
      final item = plan.candidates[index];
      final cursor = index == row ? '›' : ' ';
      buffer.write('$cursor ${_cell(item, InitOption.use).padRight(5)}');
      buffer.write(_fit(item.unit, nameWidth).padRight(nameWidth));
      for (final option in InitOption.values.skip(1)) {
        buffer.write(_cell(item, option).padRight(_cellWidth(option)));
      }
      buffer.writeln();
    }
    return _finish(buffer);
  }

  String _card() {
    final item = candidate;
    final buffer = StringBuffer()
      ..writeln('Select release outputs')
      ..writeln()
      ..writeln('› ${item.unit}');
    for (var index = 0; index < InitOption.values.length; index++) {
      final current = InitOption.values[index];
      buffer.writeln(
        '${index == column ? '›' : ' '} ${_cell(item, current).padRight(4)} '
        '${current.label}',
      );
    }
    return _finish(buffer);
  }

  String _finish(StringBuffer buffer) {
    final availability = candidate.availability[option]!;
    buffer
      ..writeln()
      ..writeln('${option.label} — ${availability.reason}'
          '${candidate.selected.contains(option) ? ' · selected' : ''}')
      ..writeln()
      ..writeln('↑↓ unit   ←→ option   space toggle   enter review');
    if (message.isNotEmpty) buffer.writeln(message);
    return buffer.toString();
  }
}

String _cell(InitCandidate candidate, InitOption option) {
  if (option == InitOption.use) return candidate.use ? '[x]' : '[ ]';
  final availability = candidate.availability[option]!;
  if (!availability.available) return '—';
  return candidate.selected.contains(option) ? '[x]' : '[ ]';
}

int _cellWidth(InitOption option) => switch (option) {
      InitOption.binary => 9,
      InitOption.gitTag => 10,
      InitOption.pubDev => 10,
      InitOption.githubRelease => 9,
      InitOption.homebrew => 0,
      InitOption.use => 5,
    };

/// Runs one selector session and always restores the terminal modes it found.
Future<InitPlan?> runInitSelector(
  InitPlan plan,
  InitTerminal terminal, {
  bool Function()? interrupted,
}) async {
  final selector = InitSelector(plan);
  final oldLineMode = terminal.lineMode;
  final oldEchoMode = terminal.echoMode;
  final oldEchoNewlineMode = terminal.echoNewlineMode;
  try {
    terminal
      ..lineMode = false
      ..echoMode = false
      ..echoNewlineMode = false
      ..write('\x1b[?25l');
    while (!(interrupted?.call() ?? false)) {
      terminal.write('\x1b[2J\x1b[H');
      terminal.write(
        selector.render(terminal.width, height: terminal.height),
      );
      await terminal.flush();
      final result = selector.handle(readInitSelectorKey(terminal.readByte));
      if (result.action == InitSelectorAction.review) return selector.plan;
      if (result.action == InitSelectorAction.cancel) return null;
    }
    return null;
  } finally {
    // Restore input before awaiting output. Even a broken output sink must not
    // leave the operator's terminal in raw/no-echo mode.
    terminal
      ..lineMode = oldLineMode
      ..echoMode = oldEchoMode
      ..echoNewlineMode = oldEchoNewlineMode;
    terminal.write('\x1b[?25h\x1b[2J\x1b[H');
    await terminal.flush();
  }
}

String _fit(String value, int width) {
  if (value.runes.length <= width) return value;
  return '${String.fromCharCodes(value.runes.take(width - 1))}…';
}

InitSelectorKey readInitSelectorKey(int Function() readByte) {
  final first = readByte();
  if (first < 0 || first == 3) return InitSelectorKey.cancel;
  if (first == 10 || first == 13) return InitSelectorKey.review;
  if (first == 32) return InitSelectorKey.toggle;
  if (first != 27) return InitSelectorKey.ignore;
  final second = readByte();
  final third = readByte();
  if (second != 91) return InitSelectorKey.ignore;
  return switch (third) {
    65 => InitSelectorKey.up,
    66 => InitSelectorKey.down,
    67 => InitSelectorKey.right,
    68 => InitSelectorKey.left,
    _ => InitSelectorKey.ignore,
  };
}
