import 'dart:math';

import '../engine/init_plan.dart';
import '../engine/release_choice.dart';

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
  bool get useColor;
  int readByte();
  void write(String value);
  Future<void> flush();
}

enum InitSelectorKey {
  up,
  down,
  left,
  right,
  toggle,
  toggleNonRegistry,
  review,
  cancel,
  ignore,
}

enum InitSelectorAction { changed, review, cancel, ignored }

/// Pure state and rendering for the compact `rk init` matrix.
final class InitSelector {
  InitSelector(this.plan)
      : row = 0,
        column = 0,
        message = '',
        showNonRegistry = false;

  InitPlan plan;
  int row;
  int column;
  String message;
  bool showNonRegistry;

  ReleaseChoice get option => ReleaseChoice.values[column];
  InitCandidate get candidate => plan.candidates[_visibleIndexes[row]];

  List<int> get _actionableIndexes => [
        for (var index = 0; index < plan.candidates.length; index++)
          if (plan.candidates[index].availability.values.any(
            (availability) => availability.available,
          ))
            index,
      ];

  List<int> get _nonRegistryIndexes => [
        for (final index in _actionableIndexes)
          if (plan.candidates[index].vetoesRegistry) index,
      ];

  List<int> get _hiddenNonRegistryIndexes => [
        for (final index in _nonRegistryIndexes)
          if (plan.candidates[index].selected.isEmpty) index,
      ];

  List<int> get _visibleIndexes => [
        for (final index in _actionableIndexes)
          if (showNonRegistry ||
              !plan.candidates[index].vetoesRegistry ||
              plan.candidates[index].selected.isNotEmpty)
            index,
      ];

  InitSelectorAction handle(InitSelectorKey key) {
    if (key == InitSelectorKey.toggleNonRegistry) {
      if (_hiddenNonRegistryIndexes.isEmpty) {
        return InitSelectorAction.ignored;
      }
      final oldIndexes = _visibleIndexes;
      final focused = oldIndexes.isEmpty ? null : oldIndexes[row];
      showNonRegistry = !showNonRegistry;
      final newIndexes = _visibleIndexes;
      row = focused != null && newIndexes.contains(focused)
          ? newIndexes.indexOf(focused)
          : min(row, max(0, newIndexes.length - 1));
      message = showNonRegistry
          ? 'non-registry units shown'
          : 'unselected non-registry units hidden';
      return InitSelectorAction.changed;
    }
    final visibleIndexes = _visibleIndexes;
    if (visibleIndexes.isEmpty) {
      return switch (key) {
        InitSelectorKey.review => InitSelectorAction.review,
        InitSelectorKey.cancel => InitSelectorAction.cancel,
        _ => InitSelectorAction.ignored,
      };
    }
    switch (key) {
      case InitSelectorKey.up:
        row = (row - 1) % visibleIndexes.length;
        break;
      case InitSelectorKey.down:
        row = (row + 1) % visibleIndexes.length;
        break;
      case InitSelectorKey.left:
        column = (column - 1) % ReleaseChoice.values.length;
        break;
      case InitSelectorKey.right:
        column = (column + 1) % ReleaseChoice.values.length;
        break;
      case InitSelectorKey.toggle:
        final toggled = plan.toggle(visibleIndexes[row], option);
        plan = toggled.plan;
        message = toggled.message;
        row = min(row, max(0, _visibleIndexes.length - 1));
        return InitSelectorAction.changed;
      case InitSelectorKey.toggleNonRegistry:
        throw StateError('handled before candidate navigation');
      case InitSelectorKey.review:
        return InitSelectorAction.review;
      case InitSelectorKey.cancel:
        return InitSelectorAction.cancel;
      case InitSelectorKey.ignore:
        return InitSelectorAction.ignored;
    }
    message = '';
    return InitSelectorAction.changed;
  }

  String render(int width, {int height = 24, bool useColor = false}) {
    if (_visibleIndexes.isEmpty) return _empty();
    return width >= 88 ? _matrix(height, useColor) : _card(useColor);
  }

  String _matrix(int height, bool useColor) {
    const nameWidth = 24;
    final indexes = _visibleIndexes;
    final visibleRows = min(indexes.length, max(3, height - 10));
    final start = min(
      max(0, row - visibleRows ~/ 2),
      max(0, indexes.length - visibleRows),
    );
    final end = min(indexes.length, start + visibleRows);
    final buffer = StringBuffer()
      ..writeln(
        'Select release outputs'
        '${_visibilityLabel()}'
        '${visibleRows < indexes.length ? ' · ${row + 1}/${indexes.length}' : ''}',
      )
      ..writeln()
      ..writeln('                         Produce              Publish')
      ..writeln(
        '  Unit${' ' * (nameWidth - 4)}'
        'Binary   Git tag   pub.dev   GitHub   Homebrew',
      );
    for (var index = start; index < end; index++) {
      final item = plan.candidates[indexes[index]];
      final cursor = index == row ? '›' : ' ';
      buffer.write('$cursor ${_fit(item.unit, nameWidth).padRight(nameWidth)}');
      for (final option in ReleaseChoice.values) {
        final marker = _cell(item, option);
        final focused = index == row && option == this.option;
        buffer
          ..write(focused ? _focused(marker, useColor) : marker)
          ..write(' ' * max(0, _cellWidth(option) - marker.length));
      }
      buffer.writeln();
    }
    return _finish(buffer);
  }

  String _card(bool useColor) {
    final item = candidate;
    final buffer = StringBuffer()
      ..writeln('Select release outputs${_visibilityLabel()}')
      ..writeln()
      ..writeln('› ${item.unit}');
    for (var index = 0; index < ReleaseChoice.values.length; index++) {
      final current = ReleaseChoice.values[index];
      final marker = _cell(item, current);
      buffer.writeln(
        '${index == column ? '›' : ' '} '
        '${index == column ? _focused(marker, useColor) : marker}'
        '${' ' * max(0, 4 - marker.length)} ${current.selectorLabel}',
      );
    }
    return _finish(buffer);
  }

  String _finish(StringBuffer buffer) {
    final availability = candidate.availability[option]!;
    buffer
      ..writeln()
      ..writeln(
        '${option.selectorLabel} — ${availability.reason}'
        '${candidate.selected.contains(option) ? ' · selected' : ''}',
      )
      ..writeln()
      ..writeln(
        '↑↓ unit   ←→ option   space toggle   '
        '${_hiddenNonRegistryIndexes.isEmpty ? '' : showNonRegistry ? 'a hide   ' : 'a show   '}'
        'enter review   q cancel',
      );
    if (message.isNotEmpty) buffer.writeln(message);
    return buffer.toString();
  }

  String _visibilityLabel() => _hiddenNonRegistryIndexes.isEmpty
      ? ''
      : showNonRegistry
          ? ' · ${_hiddenNonRegistryIndexes.length} non-registry shown'
          : ' · ${_hiddenNonRegistryIndexes.length} non-registry hidden';

  String _empty() {
    final hidden = _hiddenNonRegistryIndexes.length;
    final buffer = StringBuffer()
      ..writeln(
        'Select release outputs'
        '${hidden == 0 ? '' : ' · $hidden non-registry hidden'}',
      )
      ..writeln()
      ..writeln('No default release candidates.')
      ..writeln()
      ..writeln(
        '${hidden == 0 ? '' : 'a show   '}'
        'enter review   q cancel',
      );
    if (message.isNotEmpty) buffer.writeln(message);
    return buffer.toString();
  }
}

String _cell(InitCandidate candidate, ReleaseChoice option) {
  final availability = candidate.availability[option]!;
  if (!availability.available) return '—';
  return candidate.selected.contains(option) ? '[x]' : '[ ]';
}

String _focused(String value, bool useColor) =>
    useColor ? '\x1b[1;36m$value\x1b[0m' : value;

int _cellWidth(ReleaseChoice option) => switch (option) {
      ReleaseChoice.binary => 9,
      ReleaseChoice.gitTag => 10,
      ReleaseChoice.pubDev => 10,
      ReleaseChoice.githubRelease => 9,
      ReleaseChoice.homebrew => 0,
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
        selector.render(
          terminal.width,
          height: terminal.height,
          useColor: terminal.useColor,
        ),
      );
      await terminal.flush();
      final action = selector.handle(readInitSelectorKey(terminal.readByte));
      if (action == InitSelectorAction.review) return selector.plan;
      if (action == InitSelectorAction.cancel) return null;
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
  if (first == 113 || first == 81) return InitSelectorKey.cancel;
  if (first == 97 || first == 65) {
    return InitSelectorKey.toggleNonRegistry;
  }
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
