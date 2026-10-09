import 'dart:async';
import 'dart:io';
import 'dart:math' show max, min;

import '../engine/diagnostic.dart';
import '../engine/git.dart';
import 'report.dart';
import 'timeline.dart';
import '../engine/verdict.dart';

part 'board.dart';

/// What a checkout is at, in one phrase: `main@abc1234 · 2 uncommitted`.
/// The commit rides beside the branch for a reader; a document keeps them
/// apart, because `branch` promises a branch name.
String sourceIdentity(String? branch, String? commit, int? uncommitted) => [
  if (branch != null && commit != null) '$branch@$commit',
  if (branch != null && commit == null) branch,
  if (branch == null && commit != null) commit,
  if (uncommitted != null && uncommitted > 0) '$uncommitted uncommitted',
].join(' · ');

/// Makes untrusted text inert on a terminal while leaving report evidence raw.
///
/// ESC is not the only terminal control: C0, DEL, and C1 bytes can ring a
/// bell, move the cursor, clear the screen, or begin a control sequence. Human
/// output spells them as ASCII escapes. JSON and diagnosis attachments never
/// pass through this renderer and retain the provider's original evidence.
String terminalSafeText(String text) {
  String? escaped;
  var start = 0;
  final runes = text.runes.toList();
  for (var index = 0; index < runes.length; index++) {
    final rune = runes[index];
    final control = rune < 0x20 || (rune >= 0x7f && rune <= 0x9f);
    if (!control) continue;
    escaped ??= '';
    escaped += String.fromCharCodes(runes.sublist(start, index));
    escaped += rune <= 0xff
        ? '\\x${rune.toRadixString(16).padLeft(2, '0')}'
        : '\\u{${rune.toRadixString(16)}}';
    start = index + 1;
  }
  if (escaped == null) return text;
  return escaped + String.fromCharCodes(runes.sublist(start));
}

/// Control, bidirectional and zero-width characters: what would move the
/// cursor or reorder a line rather than show in it.
final invisibleCharacters = RegExp(
  r'[\x00-\x1f\x7f\u200B-\u200F\u202A-\u202E\u2060-\u206F\uFEFF]',
);

/// [text] as one line of at most [max] characters: what is invisible
/// becomes a space, and a longer line ends in '…'. How much of a provider's
/// note fits is a matter of display, never a reason to stop a release.
String oneLine(String text, {int max = 120}) {
  final line = text.replaceAll(invisibleCharacters, ' ').trim();
  if (line.runes.length <= max) return line;
  return '${String.fromCharCodes(line.runes.take(max - 1))}…';
}

/// How a line reads at a glance.
///
/// A small mark vocabulary rather than one per state: anything finer is carried by the
/// words on the line, which the reader has to read anyway.
enum Mark {
  /// Done or proven.
  done('✓'),

  /// Already satisfied; nothing to do.
  satisfied('·'),

  /// Blocked, conflicting, or failed.
  blocked('✗'),

  /// Your next move.
  next('→'),

  /// Nonblocking, but worth seeing before acting.
  warning('!'),

  /// Neither: a plain line.
  none(' ');

  const Mark(this.glyph);
  final String glyph;

  /// The mark a verdict earns.
  ///
  /// One definition, because two commands mapping this themselves is how
  /// the line a person reads and the document a caller keys on end up
  /// disagreeing about severity.
  static Mark of(Verdict verdict) => switch (verdict) {
    Verdict.exact => satisfied,
    Verdict.conflict => blocked,
    // Absent is work to do and unknown is work rk could not rule out.
    // Neither earns a glyph; the words separate them.
    Verdict.absent || Verdict.unknown => none,
  };

  /// What the glyph is drawn in when nothing says otherwise.
  RuntimeState get state => switch (this) {
    done => RuntimeState.success,
    satisfied => RuntimeState.satisfied,
    blocked => RuntimeState.failure,
    next => RuntimeState.active,
    warning => RuntimeState.attention,
    none => RuntimeState.neutral,
  };
}

/// What a subject represents before rk has observed an outcome for it.
///
/// Roles describe release topology. They are deliberately separate from
/// [RuntimeState]: a public target that fails is a failure, not a green public
/// label beside a red failure mark. Commands pass typed meaning and this file
/// remains the only place that knows ANSI colour numbers.
enum VisualRole {
  primary,
  secondary,
  localWork,
  checkpoint,
  requirement,
  releaseTarget,
  operatorAction,
}

/// What rk observed or is doing now.
///
/// A non-neutral state overrides a subject's [VisualRole]. This gives every
/// operational row one answer at a glance while a source-only plan can use
/// roles to describe its topology.
enum RuntimeState {
  neutral,
  active,
  satisfied,
  success,
  attention,
  failure;

  static RuntimeState of(Verdict verdict) => switch (verdict) {
    Verdict.exact => satisfied,
    Verdict.conflict => failure,
    Verdict.unknown => attention,
    Verdict.absent => neutral,
  };

  /// What a heading over rows in [states] is drawn in: a failure or an
  /// attention among them wins, rows that all agree are that, and a mix is
  /// still active.
  static RuntimeState agreed(Iterable<RuntimeState> states) {
    final distinct = states.toSet();
    if (distinct.contains(failure)) return failure;
    if (distinct.contains(attention)) return attention;
    return distinct.length == 1 ? distinct.single : active;
  }
}

/// One styled fragment whose unstyled [text] remains the output contract.
final class OutputSpan {
  const OutputSpan(
    this.text, {
    this.role = VisualRole.primary,
    this.strong = false,
  });

  final String text;
  final VisualRole role;
  final bool strong;
}

/// Everything rk prints goes through here, so terseness, collapse, and the
/// non-TTY contract are enforced in one place rather than per command.
///
/// The rules this encodes, from the RFC: rk does not narrate itself; a running
/// step expands and a finished one collapses; and a pipe sees the same words
/// the terminal ends up showing, with no cursor movement. The one exception
/// is time: a terminal's settled rows keep how long they ran, and a pipe's
/// transcript does not. A pipe hears of a step still running after ten
/// seconds once, without a time or a count, and warnings in release order.
class Output {
  Output({
    required this.sink,
    required this.isTerminal,
    bool useColor = true,
    int? terminalWidth,
    int? Function()? terminalWidthReader,
    Report? report,
    Elapsed Function()? clock,
  }) : useColor = isTerminal && useColor,
       _terminalWidth = terminalWidth,
       _terminalWidthReader = terminalWidthReader,
       report = report ?? Report('rk'),
       _clock = clock ?? _wallClock,
       timeline = RunTimeline(clock ?? _wallClock);

  /// Writes to stdout, detecting a terminal and honouring `NO_COLOR`.
  ///
  /// [json] moves the prose to nowhere: `--json` is the named machine surface
  /// rather than an addition to the human one, so a caller parsing stdout is
  /// never handed both. The report is still recorded, because the recording
  /// happens inside the same calls that would have printed.
  factory Output.stdio({bool json = false, required String command}) {
    final attached = stdout.hasTerminal && !json;
    final noColor = Platform.environment.containsKey('NO_COLOR');
    final terminal =
        attached && Platform.environment['TERM']?.toLowerCase() != 'dumb';
    return Output(
      sink: json ? _discard : stdout.write,
      isTerminal: terminal,
      useColor: terminal && !noColor,
      terminalWidthReader: attached ? _stdoutWidth : null,
      report: Report(command),
    );
  }

  static void _discard(String _) {}

  static int? _stdoutWidth() {
    try {
      final width = stdout.terminalColumns;
      return width > 0 ? width : null;
    } on Object {
      return null;
    }
  }

  static Elapsed _wallClock() {
    final stopwatch = Stopwatch()..start();
    return () => stopwatch.elapsed;
  }

  final void Function(String) sink;

  /// Spinners, transient lines, and cursor movement happen only here.
  final bool isTerminal;

  final bool useColor;

  /// Columns available on an attached terminal.
  ///
  /// Transient rows are shortened to stay one physical row, because cursor-up
  /// erasure depends on that. Settled rows are instead wrapped without losing
  /// words, with their continuation indented so narrow output remains readable.
  /// A pipe has no width and remains byte-for-byte append-only.
  final int? _terminalWidth;
  final int? Function()? _terminalWidthReader;

  int? get terminalWidth => _terminalWidthReader?.call() ?? _terminalWidth;

  /// What a caller is told, recorded by the same calls that print.
  final Report report;

  final Elapsed Function() _clock;

  /// This run's phases, rows and waits on a person, for the closing summary
  /// and `--timings`.
  final RunTimeline timeline;

  Board? _board;

  /// A fixed-height board of rows. Work is handed its rows; whoever made
  /// the board is the one that ends it, with settle, conclude or discard.
  Board board(
    String title, {
    Duration delay = const Duration(milliseconds: 80),
    bool heartbeat = false,
    Duration heartbeatAfter = const Duration(seconds: 10),
    bool elapsed = true,
  }) {
    final previous = _board;
    if (previous != null) {
      // A board still live when its successor arrives was never resolved
      // by its owner — the same bug [close] guards. Say so loudly in
      // checked mode; reap it regardless, so two boards can never paint
      // one terminal.
      assert(false, 'a live progress board was never resolved by its owner');
      previous.discard();
    }
    _yieldToProse();
    return _board = Board._(
      this,
      title,
      delay,
      heartbeat: heartbeat,
      heartbeatAfter: heartbeatAfter,
      elapsed: elapsed,
    );
  }

  /// A heading. Callers space their own sections; this adds nothing.
  void heading(String text) {
    _yieldToProse();
    _writeSettled(text, continuationPrefix: '  ', strong: true);
  }

  /// Renders a fixed help document without changing its plain-text bytes.
  ///
  /// Help is deliberately styled here rather than by each command: section
  /// labels are structure, invocations are operator actions, and explanatory
  /// copy stays neutral. JSON keeps the same unstyled document in `next`.
  void help(String text, {int depth = 0}) {
    _yieldToProse();
    final prefix = depth == 0 ? '' : '  ${'  ' * depth}';
    final endsWithNewline = text.endsWith('\n');
    final lines = text.split('\n');
    if (endsWithNewline) lines.removeLast();
    for (final (index, line) in lines.indexed) {
      sink(prefix);
      sink(_render(_helpSpans(line)));
      if (index < lines.length - 1 || endsWithNewline) sink('\n');
    }
  }

  static List<OutputSpan> _helpSpans(String line) {
    if (line.isEmpty) return const [OutputSpan('')];
    if (!line.startsWith(' ')) {
      final colon = line.indexOf(':');
      if (colon > 0 && colon < 12) {
        return [
          OutputSpan(line.substring(0, colon + 1), strong: true),
          OutputSpan(line.substring(colon + 1)),
        ];
      }
      return [OutputSpan(line, strong: true)];
    }

    final trimmed = line.trimLeft();
    final isInvocation =
        trimmed == 'rk' || trimmed.startsWith('rk ') || trimmed.startsWith('-');
    final match = isInvocation
        ? RegExp(r'^(\s*)(.+?)(\s{2,})(\S.*)$').firstMatch(line)
        : null;
    if (match == null) {
      return [OutputSpan(line, role: VisualRole.secondary)];
    }
    return [
      OutputSpan(match.group(1)!),
      OutputSpan(match.group(2)!, role: VisualRole.operatorAction),
      OutputSpan(match.group(3)!),
      OutputSpan(match.group(4)!),
    ];
  }

  /// The repository line, recorded in parts so a caller is not left parsing
  /// "keybay · main · 2 uncommitted" back into fields. [git] is what was read
  /// of it, when anything was, and each command counts [uncommitted] its own
  /// way. With [source], the record says how a stage would be named: by its
  /// commit, or not at all yet. [show] false records it without a heading.
  void repository(
    String name, {
    GitState? git,
    int? uncommitted,
    bool source = false,
    bool show = true,
  }) {
    final commit = git != null && git.hasCommit;
    report.repository(
      name: name,
      branch: git?.branch,
      uncommitted: uncommitted,
      head: commit ? git.head : null,
      remote: git?.originUrl,
      sourceBinding: source ? (commit ? 'gitCommit' : 'unbound') : null,
      sourceComparison: source ? (commit ? 'exact' : 'unavailable') : null,
    );
    if (!show) return;
    final identity = sourceIdentity(
      git?.branch,
      commit ? git.shortHead : null,
      uncommitted,
    );
    heading(identity.isEmpty ? name : '$name · $identity');
  }

  /// Opens a unit. Steps printed after this belong to it.
  void unit(
    String name, {
    required String version,
    required String? tag,
    String? state,
    String? display,
  }) {
    report.unit(name: name, version: version, tag: tag);
    blank();
    // › for becomes and for sequence, everywhere inline: the gutter's → is
    // reserved for "your next move", and three reviewers independently
    // caught it moonlighting.
    line(
      name,
      note:
          display ??
          (state == null ? '$version › $tag' : '$version › $tag · $state'),
      // The unit's own line is a sentence, not a column: what follows the
      // name belongs beside it, not at the note column the rows below
      // share.
      labelWidth: 0,
      strong: true,
      noteRole: VisualRole.secondary,
    );
  }

  /// Ends the run's rendering.
  ///
  /// A repeating timer keeps a Dart isolate alive, so an activity abandoned by
  /// a thrown exception would leave rk running with nothing to do — a hang,
  /// which in CI is worse than a crash because nothing reports it. Calling this
  /// on the way out is what makes that impossible rather than unlikely.
  void close() {
    final board = _board;
    if (board != null) {
      // Every board's owner must resolve it — settle, conclude, or discard.
      // A board alive at close is an owner bug; say so loudly in checked
      // mode, and still reap its timers so a release build cannot hang.
      assert(false, 'a live progress board was never resolved by its owner');
      board.discard();
    }
    flushWarnings();
    _yieldToProse();
  }

  void blank() {
    _yieldToProse();
    sink('\n');
  }

  /// One line of the tree, indented by [depth] levels of two spaces.
  ///
  /// [note] is the fact; [detail] is the part that only matters when it
  /// differs, and is aligned so a column of them stays readable.
  ///
  /// Semantic roles and states colour the words themselves, not only the
  /// gutter. Layout is computed on plain text and colour applied after, so a
  /// painted label never shifts its column; `NO_COLOR` and pipes get the same
  /// characters uncoloured.
  void line(
    String label, {
    Mark mark = Mark.none,
    String? note,
    int depth = 0,
    int labelWidth = 16,
    VisualRole role = VisualRole.primary,
    RuntimeState? state,
    bool strong = false,
    VisualRole noteRole = VisualRole.primary,
    RuntimeState? noteState,
  }) {
    _yieldToProse();
    label = terminalSafeText(label);
    note = note == null ? null : terminalSafeText(note);
    final effectiveState = state ?? mark.state;
    final effectiveNoteState = noteState ?? effectiveState;
    final plainGlyph = mark == Mark.none ? ' ' : mark.glyph;
    final paintedGlyph = mark == Mark.none
        ? ' '
        : _style(mark.glyph, state: effectiveState);

    // The mark sits beside its row, at the row's indent: a nested row's mark
    // reads as its bullet, not as a stray in the left margin. The text
    // columns are where they would be without it, and the indent is part of
    // what is padded, so the note column stays put as the tree deepens
    // rather than drifting right with it.
    final indent = '  ' * depth;
    final indented = '$indent$label';
    final indentedWidth = displayWidth(indented);
    final pad = labelWidth - displayWidth(indent);
    final plain = note == null
        ? '$indent$plainGlyph $label'
        : indentedWidth >= labelWidth
        ? '$indent$plainGlyph $label $note'
        : '$indent$plainGlyph ${_padToWidth(label, pad)} $note';
    final width = terminalWidth;
    if (width != null && displayWidth(plain) > width) {
      final firstPrefix = '$indent$plainGlyph ';
      final paintedFirstPrefix = '$indent$paintedGlyph ';
      final continuationPrefix = '${' ' * firstPrefix.runes.length}  ';
      _writeSettled(
        label,
        firstPrefix: firstPrefix,
        paintedFirstPrefix: paintedFirstPrefix,
        continuationPrefix: continuationPrefix,
        role: role,
        state: effectiveState,
        strong: strong,
      );
      if (note != null) {
        _writeSettled(
          note,
          firstPrefix: continuationPrefix,
          continuationPrefix: continuationPrefix,
          role: noteRole,
          state: effectiveNoteState,
        );
      }
      return;
    }

    final glyph = '$indent$paintedGlyph';
    if (note == null) {
      sink(
        '$glyph '
        '${_style(label, role: role, state: effectiveState, strong: strong)}\n',
      );
      return;
    }
    if (indentedWidth >= labelWidth) {
      // Too long to keep the note on the grid. It follows the label anyway,
      // because a note describes the line it is on: given its own line it reads
      // as a fact about nothing, and "permanent" floating alone is worse than
      // "permanent" out of column.
      sink(
        '$glyph '
        '${_style(label, role: role, state: effectiveState, strong: strong)} '
        '${_style(note, role: noteRole, state: effectiveNoteState)}\n',
      );
      return;
    }
    final padded = _padToWidth(label, pad);
    sink(
      '$glyph '
      '${_style(padded, role: role, state: effectiveState, strong: strong)} '
      '${_style(note, role: noteRole, state: effectiveNoteState)}\n',
    );
  }

  /// RK's complete terminal colour vocabulary.
  ///
  /// Standard ANSI colours let the terminal theme choose contrast. Styling is
  /// applied per span and reset immediately; it never crosses a newline or
  /// leaks into a native command.
  String _style(
    String text, {
    VisualRole role = VisualRole.primary,
    RuntimeState state = RuntimeState.neutral,
    bool strong = false,
  }) {
    final safe = terminalSafeText(text);
    if (!useColor || safe.isEmpty) return safe;
    final color = switch (state) {
      RuntimeState.neutral => switch (role) {
        VisualRole.primary => null,
        VisualRole.secondary => '90', // grey
        VisualRole.localWork => '34', // blue
        VisualRole.checkpoint => '35', // violet/magenta
        VisualRole.requirement => '33', // amber/yellow
        VisualRole.releaseTarget || VisualRole.operatorAction => '36', // cyan
      },
      RuntimeState.active => '36', // cyan
      RuntimeState.satisfied => '90', // grey
      RuntimeState.success => '32', // green
      RuntimeState.attention => '33', // yellow
      RuntimeState.failure => '31', // red
    };
    final codes = [if (strong) '1', if (color != null) color];
    if (codes.isEmpty) return safe;
    return '\x1b[${codes.join(';')}m$safe\x1b[0m';
  }

  String _render(Iterable<OutputSpan> spans) => spans
      .map((span) => _style(span.text, role: span.role, strong: span.strong))
      .join();

  /// Writes one pre-laid-out line made of semantic spans.
  ///
  /// The caller owns wrapping and may use [plainWidth] to select a fallback.
  /// This is the graph renderer's mixed-colour surface; ordinary command rows
  /// should continue through [line] so they receive rk's width policy.
  void spans(Iterable<OutputSpan> spans) {
    _yieldToProse();
    final values = List<OutputSpan>.unmodifiable(spans);
    assert(values.every((span) => !span.text.contains('\n')));
    sink('${_render(values)}\n');
  }

  static int plainWidth(Iterable<OutputSpan> spans) =>
      spans.fold(0, (width, span) => width + displayWidth(span.text));

  /// Terminal columns occupied by inert human text.
  static int displayWidth(String text) => terminalSafeText(
    text,
  ).runes.fold(0, (width, rune) => width + _terminalRuneWidth(rune));

  static String _padToWidth(String text, int width) {
    final missing = width - displayWidth(text);
    return missing <= 0 ? text : '$text${' ' * missing}';
  }

  /// Free-form prose, wrapped in the same indentation as the tree.
  void say(
    String text, {
    int depth = 0,
    VisualRole role = VisualRole.primary,
    RuntimeState state = RuntimeState.neutral,
    bool strong = false,
  }) {
    _yieldToProse();
    final prefix = '  ${'  ' * depth}';
    for (final part in text.split('\n')) {
      final repeatsComment = part.startsWith('# ');
      _writeSettled(
        part,
        firstPrefix: prefix,
        continuationPrefix: '$prefix  ${repeatsComment ? '# ' : ''}',
        role: role,
        state: state,
        strong: strong,
      );
    }
  }

  /// A terminal prompt, using the same width policy as settled prose while
  /// leaving the cursor after the final space for the answer.
  void prompt(String text) {
    _yieldToProse();
    final body = text.trimRight();
    _writeSettled(
      body,
      continuationPrefix: '  ',
      role: VisualRole.operatorAction,
      strong: true,
      endWithNewline: false,
    );
    if (text.length != body.length) sink(' ');
  }

  void _writeSettled(
    String text, {
    String firstPrefix = '',
    String? paintedFirstPrefix,
    required String continuationPrefix,
    VisualRole role = VisualRole.primary,
    RuntimeState state = RuntimeState.neutral,
    bool strong = false,
    bool endWithNewline = true,
  }) {
    text = terminalSafeText(text);
    final width = terminalWidth;
    if (width == null ||
        displayWidth(firstPrefix) + displayWidth(text) <= width) {
      sink(
        '${paintedFirstPrefix ?? firstPrefix}'
        '${_style(text, role: role, state: state, strong: strong)}'
        '${endWithNewline ? '\n' : ''}',
      );
      return;
    }

    final fragments = _wrapSettled(
      text,
      firstWidth: width - displayWidth(firstPrefix),
      continuationWidth: width - displayWidth(continuationPrefix),
    );
    for (final (index, fragment) in fragments.indexed) {
      final first = index == 0;
      final prefix = first
          ? paintedFirstPrefix ?? firstPrefix
          : continuationPrefix;
      final newline = index < fragments.length - 1 || endWithNewline;
      sink(
        '$prefix'
        '${_style(fragment, role: role, state: state, strong: strong)}'
        '${newline ? '\n' : ''}',
      );
    }
  }

  static List<String> _wrapSettled(
    String text, {
    required int firstWidth,
    required int continuationWidth,
  }) {
    final words = text.trim().split(RegExp(r'\s+'));
    if (words.length == 1 && words.single.isEmpty) return const [''];

    final lines = <String>[];
    var width = firstWidth < 1 ? 1 : firstWidth;
    var current = '';

    void flush() {
      if (current.isEmpty) return;
      lines.add(current);
      current = '';
      width = continuationWidth < 1 ? 1 : continuationWidth;
    }

    for (final word in words) {
      final runes = word.runes.toList();
      var offset = 0;
      while (offset < runes.length) {
        final separator = current.isEmpty ? 0 : 1;
        final available = width - displayWidth(current) - separator;
        if (available <= 0) {
          flush();
          continue;
        }
        final remaining = String.fromCharCodes(runes.skip(offset));
        if (displayWidth(remaining) <= available) {
          current =
              '$current${separator == 0 ? '' : ' '}'
              '$remaining';
          offset = runes.length;
          continue;
        }
        if (current.isNotEmpty) {
          flush();
          continue;
        }
        var take = 0;
        var used = 0;
        while (offset + take < runes.length) {
          final runeWidth = _terminalRuneWidth(runes[offset + take]);
          if (take > 0 && used + runeWidth > available) break;
          take++;
          used += runeWidth;
          if (used > available) break;
        }
        current = String.fromCharCodes(runes.skip(offset).take(take));
        offset += take;
        flush();
      }
    }
    flush();
    return lines.isEmpty ? const [''] : lines;
  }

  /// Makes room for a durable line.
  ///
  /// The renderer draws; the coordinator judges. Prose never destroys a
  /// live board — it yields: the board's region clears so the line joins
  /// the transcript, and the next frame repaints it beneath. Boards end
  /// only by their owner's settle, conclude, or discard.
  void _yieldToProse() {
    _board?._yieldToProse();
  }

  /// Runs [body] holding back its halts, then says the most serious once.
  /// Work running side by side stops together, rather than one halt landing
  /// among the others' progress.
  Future<T> holdingHalts<T>(Future<T> Function() body) async {
    _holdingHalts++;
    try {
      return await body();
    } finally {
      if (--_holdingHalts == 0) {
        final held = _heldStop;
        _heldStop = null;
        if (held != null) halt(held);
      }
    }
  }

  var _holdingHalts = 0;
  Stop? _heldStop;

  /// Says how the run stopped, in the plain sentence that opens every halt.
  ///
  /// A site says why it stops; what that means for the whole run is decided
  /// here, once, from whether anything public has changed by now. A lane
  /// that stops while another publishes beside it is told so, whichever
  /// finished first.
  void halt(Stop stop) {
    if (_holdingHalts > 0) {
      _heldStop = Stop.worst([?_heldStop, stop]);
      return;
    }
    flushWarnings();
    final kind = HaltKind.of(stop, changed: report.publicChanged);
    report.halt(kind);
    blank();
    say(kind.sentence);
    blank();
  }

  /// A problem and its remedy.
  ///
  /// Stable codes stay in `--json`; the default human surface carries only
  /// the sentence and action they identify.
  void problem(
    Diagnostic diagnostic, {
    String? unit,
    String? target,
    int depth = 0,
  }) {
    flushWarnings();
    report.problem(diagnostic, unit: unit, target: target);
    final where = diagnostic.source == null ? '' : '${diagnostic.source}  ';
    line(
      '$where${diagnostic.message}',
      mark: Mark.blocked,
      depth: depth,
      state: RuntimeState.failure,
    );
    if (diagnostic.remedy != null) say(diagnostic.remedy!, depth: depth + 1);
  }

  /// Every problem in one pass, so a fix cycle is one edit round.
  void problems(List<Diagnostic> found) {
    for (final diagnostic in found) {
      problem(diagnostic);
    }
  }

  /// Warnings recorded but not yet shown: see [deferWarning].
  final List<({Diagnostic diagnostic, String? unit, String? target})>
  _deferredWarnings = [];

  /// Records a nonblocking diagnostic now, and shows it later with the run's
  /// other warnings, in one section: before the run's next problem, halt or
  /// next move, or at [flushWarnings]. Units staged side by side each find
  /// their own; said as they arrive, they made a section per unit and
  /// repeated the remedy they share under every one.
  void deferWarning(Diagnostic diagnostic, {String? unit, String? target}) {
    _deferredWarnings.add((diagnostic: diagnostic, unit: unit, target: target));
  }

  /// Shows every deferred warning under one heading, and records it in the
  /// report. Warnings that share a remedy are listed together, and the remedy
  /// is said once, after them. [order] names units in the order their
  /// warnings are said: units staged side by side finish in any order, and
  /// the run reads the same either way.
  void flushWarnings({List<String> order = const []}) {
    if (_deferredWarnings.isEmpty) return;
    final rank = {for (final (index, unit) in order.indexed) unit: index};
    final deferred = [..._deferredWarnings.indexed]
      ..sort((a, b) {
        final byUnit = (rank[a.$2.unit] ?? order.length).compareTo(
          rank[b.$2.unit] ?? order.length,
        );
        return byUnit != 0 ? byUnit : a.$1.compareTo(b.$1);
      });
    _deferredWarnings.clear();
    final seen = <String>{};
    final byRemedy = <String?, List<Diagnostic>>{};
    for (final (_, (:diagnostic, :unit, :target)) in deferred) {
      final key = '$unit\u0000${diagnostic.code}\u0000${diagnostic.message}';
      if (!seen.add(key)) continue;
      report.warning(diagnostic, unit: unit, target: target);
      byRemedy.putIfAbsent(diagnostic.remedy, () => []).add(diagnostic);
    }
    blank();
    heading('Warnings');
    for (final MapEntry(key: remedy, value: warnings) in byRemedy.entries) {
      for (final diagnostic in warnings) {
        final where = diagnostic.source == null ? '' : '${diagnostic.source}  ';
        line(
          '$where${diagnostic.message}',
          mark: Mark.warning,
          depth: 1,
          state: RuntimeState.attention,
        );
      }
      if (remedy != null) say(remedy, depth: 2);
    }
  }

  /// A nonblocking diagnostic. Its stable code remains machine-readable.
  void warning(
    Diagnostic diagnostic, {
    String? unit,
    String? target,
    int depth = 0,
  }) {
    report.warning(diagnostic, unit: unit, target: target);
    final where = diagnostic.source == null ? '' : '${diagnostic.source}  ';
    line(
      '$where${diagnostic.message}',
      mark: Mark.warning,
      depth: depth,
      state: RuntimeState.attention,
    );
    if (diagnostic.remedy != null) {
      say(diagnostic.remedy!, depth: depth + 1);
    }
  }

  /// The next command, which is what a reader wants after being told to act.
  void next(String command, {int depth = 0}) {
    flushWarnings();
    report.next(command);
    // Marked by position, not by content: two identical lines are two lines,
    // and only the first is the reader's next move.
    for (final (index, part) in command.split('\n').indexed) {
      line(
        part,
        mark: index == 0 ? Mark.next : Mark.none,
        depth: depth,
        role: VisualRole.operatorAction,
      );
    }
  }
}

int _terminalRuneWidth(int rune) {
  if ((rune >= 0x0300 && rune <= 0x036f) ||
      (rune >= 0x1ab0 && rune <= 0x1aff) ||
      (rune >= 0x1dc0 && rune <= 0x1dff) ||
      (rune >= 0xfe20 && rune <= 0xfe2f)) {
    return 0;
  }
  if (rune >= 0x1100 &&
      (rune <= 0x115f ||
          rune == 0x2329 ||
          rune == 0x232a ||
          (rune >= 0x2e80 && rune <= 0xa4cf && rune != 0x303f) ||
          (rune >= 0xac00 && rune <= 0xd7a3) ||
          (rune >= 0xf900 && rune <= 0xfaff) ||
          (rune >= 0xfe10 && rune <= 0xfe19) ||
          (rune >= 0xfe30 && rune <= 0xfe6f) ||
          (rune >= 0xff00 && rune <= 0xff60) ||
          (rune >= 0xffe0 && rune <= 0xffe6) ||
          (rune >= 0x1f300 && rune <= 0x1faff) ||
          (rune >= 0x20000 && rune <= 0x3fffd))) {
    return 2;
  }
  return 1;
}

/// Why a site stops, in order of seriousness. What that means for the whole
/// run is [HaltKind.of] it, once the run knows whether anything public
/// changed.
enum Stop {
  /// Refused before acting on what it stopped at.
  refused,

  /// Stopped between acts: what completed was read back and stays done.
  partway,

  /// Acted, then lost sight of the result.
  lostTrack,

  /// Something re-running will not resolve.
  unfixable;

  static Stop worst(Iterable<Stop> stops) =>
      stops.reduce((left, right) => left.index >= right.index ? left : right);
}

/// Which of the two questions an operator has a halt is answering.
enum HaltKind {
  /// No public target changed. Private preparation or native login may have.
  beforeActing('rk stopped. no public target changed. safe to re-run.'),

  /// The run stopped between acts; what completed stays done, nothing was
  /// lost sight of, and the next run continues from what it finds.
  ///
  /// Added with the local chain, whose failures — a build that does not
  /// compile, a notarization Apple rejects — stop a run that may already
  /// have acted (a pushed tag). "nothing changed" would be false there, and
  /// "lost sight of the result" would be too: the result was read, and it
  /// was a refusal.
  stoppedPartway(
    'rk stopped partway. everything already done is real and stays done; '
    're-running resumes after it.',
  ),

  /// Something may have happened; the next run classifies what it finds.
  lostTrack(
    'rk acted, then lost sight of the result. an effect may exist. still '
    'safe to re-run.',
  ),

  /// Something is wrong that re-running will not resolve.
  unfixableByRerun(
    'No public targets changed. Resolve the conflict before retrying.',
  ),

  /// rk acted, read the result back, and the result is permanently wrong.
  ///
  /// The pre-act sentence said "rk did not act" about the worst path rk has
  /// — a mismatch read back one step after a real publish — which answered
  /// the halt's own first question falsely.
  actedAndUnfixable(
    'rk acted, and what it read back cannot be fixed by re-running.',
  );

  const HaltKind(this.sentence);

  final String sentence;

  bool get rerunHelps => this != unfixableByRerun && this != actedAndUnfixable;

  /// What [stop] means for a run that has, or has not, [changed] a public
  /// target. [Stop] is in order for each answer, so the worst of several
  /// stops means the worst of what each would.
  static HaltKind of(Stop stop, {required bool changed}) => switch (stop) {
    Stop.refused => changed ? stoppedPartway : beforeActing,
    Stop.partway => stoppedPartway,
    Stop.lostTrack => lostTrack,
    Stop.unfixable => changed ? actedAndUnfixable : unfixableByRerun,
  };
}

/// Process exit codes, from the RFC's output contract.
class ExitCodes {
  /// Clean, complete, or blocked — blocked is a state, not a failure.
  static const ok = 0;

  /// A refusal: a validation error, a conflict, or an unknown verdict.
  static const refused = 1;

  /// The command was used incorrectly.
  static const usage = 2;

  /// rk itself failed — not a refusal, and worth different handling: a
  /// refusal has a remedy, a crash has a diagnosis directory and a bug.
  static const crashed = 3;
}

/// How long something has been running.
///
/// A function rather than a `Stopwatch` so liveness can be tested without
/// waiting: the wall clock is one implementation of it, and a test's counter is
/// another.
typedef Elapsed = Duration Function();

/// A duration in the coarsest terms that still say something: seconds under a
/// minute, then minutes, then hours. Nobody waiting on a release needs
/// milliseconds, and nobody reading "184s" converts it gladly.
String formatDuration(Duration d) {
  if (d.inSeconds < 60) return '${d.inSeconds}s';
  if (d.inMinutes < 60) {
    final seconds = d.inSeconds % 60;
    return seconds == 0 ? '${d.inMinutes}m' : '${d.inMinutes}m ${seconds}s';
  }
  final minutes = d.inMinutes % 60;
  return minutes == 0 ? '${d.inHours}h' : '${d.inHours}h ${minutes}m';
}
