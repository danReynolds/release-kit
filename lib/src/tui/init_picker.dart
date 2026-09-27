import 'dart:async';
import 'package:fleury/fleury.dart';

import '../commands/init.dart';
import '../engine/init_plan.dart';
import '../engine/release_choice.dart';
import 'matrix.dart';
import 'terminal.dart';

class InitPicker extends Notifier {
  InitPicker(this.plan, this.finish);
  InitPlan plan;
  final void Function(InitPlan?) finish;
  String message = '';
  bool showPrivate = false;
  bool failed = false;
  List<String> get notes => [...plan.notices, ...plan.binaryPlatformNotices];

  List<int> get visible => [
    for (var i = 0; i < plan.candidates.length; i++)
      if (showPrivate ||
          !plan.candidates[i].vetoesRegistry ||
          plan.candidates[i].selected.isNotEmpty)
        i,
  ];
  void togglePrivate() {
    showPrivate = !showPrivate;
    notify();
  }

  void toggle(int index, ReleaseChoice choice) {
    final result = plan.toggle(index, choice);
    failed = identical(result.plan, plan);
    plan = result.plan;
    message = result.message;
    notify();
  }
}

/// One terminal session spans selection, validation, review, and Back.
/// InitCommand still owns proposal validation and the write boundary.
class InitInteraction extends Notifier {
  InitInteraction({this.driver});
  final TerminalDriver? driver;
  Widget? page;
  InitPicker? _picker;
  Completer<InitPlan?>? _selection;
  Completer<InitReviewDecision>? _review;
  Future<int>? _running;
  int? signalExitCode;
  bool _cancelled = false;

  Future<InitPlan?> select(InitPlan plan) {
    if (_cancelled) return Future.value(null);
    final answer = Completer<InitPlan?>();
    _selection = answer;
    _picker?.dispose();
    _picker = InitPicker(plan, (value) {
      if (!answer.isCompleted) answer.complete(value);
    });
    page = InitScreen(_picker!);
    notify();
    if (_running == null) {
      _running = runMatrixScreen(
        _InitInteractionScreen(this),
        interrupt: cancel,
        driver: driver,
      );
      // A driver failure or external exit must also release the command's
      // pending prompt. close() awaits the original future for error reporting.
      unawaited(
        _running!.then(
          (_) => cancel(),
          onError: (Object error, StackTrace stack) {
            if (_selection case final pending? when !pending.isCompleted) {
              pending.completeError(error, stack);
            }
            if (_review case final pending? when !pending.isCompleted) {
              pending.completeError(error, stack);
            }
          },
        ),
      );
    }
    return answer.future;
  }

  Future<InitReviewDecision> review(String proposal, bool needsIgnore) {
    if (_cancelled) return Future.value(InitReviewDecision.cancel);
    final answer = Completer<InitReviewDecision>();
    _review = answer;
    page = InitReviewScreen(proposal, needsIgnore, (value) {
      if (!answer.isCompleted) answer.complete(value);
    }, notes: _picker?.notes ?? const []);
    notify();
    return answer.future;
  }

  void cancel() {
    _cancelled = true;
    if (_selection case final pending? when !pending.isCompleted) {
      pending.complete(null);
    }
    if (_review case final pending? when !pending.isCompleted) {
      pending.complete(InitReviewDecision.cancel);
    }
  }

  Future<void> close() async {
    cancel();
    try {
      if (_running != null) {
        exitApp();
        final code = await _running!;
        if (code != 0) signalExitCode = code;
      }
    } finally {
      _picker?.dispose();
      dispose();
    }
  }
}

class _InitInteractionScreen extends StatelessWidget {
  const _InitInteractionScreen(this.model);
  final InitInteraction model;
  @override
  Widget build(BuildContext context) {
    context.listen(model);
    return model.page ?? const Text('Preparing configuration…');
  }
}

class InitScreen extends StatefulWidget {
  const InitScreen(this.model, {super.key});
  final InitPicker model;

  @override
  State<InitScreen> createState() => _InitScreenState();
}

class _InitScreenState extends State<InitScreen> {
  final _scroll = ScrollController();
  final _notesFocus = FocusNode();
  final _cells = <(int, ReleaseChoice), FocusNode>{};
  ({String title, String body, FocusNode origin})? _reason;
  bool _showingNotes = false;
  InitPicker get model => widget.model;

  @override
  void dispose() {
    _scroll.dispose();
    _notesFocus.dispose();
    for (final node in _cells.values) {
      node.dispose();
    }
    super.dispose();
  }

  void _backFromDetails(FocusNode origin) {
    setState(() {
      _showingNotes = false;
      _reason = null;
    });
    TuiBinding.of(context).addPostFrameCallback((_) {
      if (mounted) origin.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    context.listen(model);
    final notes = model.notes;
    if (_showingNotes) {
      return MatrixDetails(
        command: 'rk init',
        title: 'Discovery notes',
        body: notes.join('\n\n'),
        onBack: () => _backFromDetails(_notesFocus),
      );
    }
    if (_reason case final reason?) {
      return MatrixDetails(
        command: 'rk init',
        title: reason.title,
        body: reason.body,
        onBack: () => _backFromDetails(reason.origin),
      );
    }
    return MatrixShell(
      command: 'rk init',
      count:
          '${model.visible.length} ${model.visible.length == 1 ? 'package' : 'packages'}',
      subtitle: 'Choose the outputs for each package.',
      message: model.message,
      failed: model.failed,
      scrollController: _scroll,
      hint: '↑↓←→ move · Space toggle',
      onEscape: () => model.finish(null),
      child: ChoiceMatrix(
        columns: ReleaseChoice.values.map((c) => c.selectorLabel).toList(),
        rows: [for (final i in model.visible) _row(i)],
      ),
      actions: [
        if (notes.isNotEmpty)
          MatrixButton(
            text: 'Discovery notes (${notes.length})',
            focusNode: _notesFocus,
            onPressed: () => setState(() => _showingNotes = true),
          ),
        if (model.plan.candidates.any((c) => c.vetoesRegistry))
          MatrixButton(
            text: model.showPrivate
                ? 'Hide private packages'
                : 'Show private packages',
            onPressed: model.togglePrivate,
          ),
        MatrixButton(text: 'Esc Cancel', onPressed: () => model.finish(null)),
        MatrixButton(
          text: 'Review configuration →',
          variant: ButtonVariant.primary,
          onPressed: model.plan.included.isEmpty
              ? null
              : () => model.finish(model.plan),
        ),
      ],
    );
  }

  MatrixRow _row(int index) {
    final package = model.plan.candidates[index];
    return MatrixRow(
      package.name,
      '${package.executables.isEmpty ? 'SDK' : 'CLI'} · ${package.version ?? 'No version'}',
      [
        for (final choice in ReleaseChoice.values)
          MatrixCell(
            focusNode: _cells.putIfAbsent((index, choice), FocusNode.new),
            title: package.availability[choice]!.available
                ? package.selected.contains(choice)
                      ? '✓ Added'
                      : 'Add'
                : 'Unavailable',
            detail: package.availability[choice]!.available
                ? _detail(package, choice)
                : 'View reason',
            semanticLabel:
                '${package.name}, ${choice.selectorLabel}: ${package.selected.contains(choice) ? 'Added' : package.availability[choice]!.reason}',
            selected: package.selected.contains(choice),
            unavailable: !package.availability[choice]!.available,
            onPressed: () {
              final availability = package.availability[choice]!;
              if (availability.available) {
                model.toggle(index, choice);
              } else {
                setState(
                  () => _reason = (
                    title: '${package.name} · ${choice.selectorLabel}',
                    body: availability.reason,
                    origin: _cells[(index, choice)]!,
                  ),
                );
              }
            },
          ),
      ],
    );
  }

  String _detail(InitCandidate package, ReleaseChoice choice) {
    for (final dependent in package.selected) {
      if (dependent.requires.contains(choice)) {
        return 'For ${dependent.selectorLabel}';
      }
    }
    return switch (choice) {
      ReleaseChoice.binary => 'Local build',
      ReleaseChoice.gitTag => 'Version tag',
      ReleaseChoice.pubDev => 'Dart package',
      ReleaseChoice.githubRelease => 'Release page',
      ReleaseChoice.homebrew => 'Tap formula',
    };
  }
}

class InitReviewScreen extends StatefulWidget {
  const InitReviewScreen(
    this.proposal,
    this.needsIgnore,
    this.finish, {
    this.notes = const [],
    super.key,
  });
  final String proposal;
  final bool needsIgnore;
  final void Function(InitReviewDecision) finish;
  final List<String> notes;

  @override
  State<InitReviewScreen> createState() => _InitReviewScreenState();
}

class _InitReviewScreenState extends State<InitReviewScreen> {
  final _scroll = ScrollController();
  final _notesFocus = FocusNode();
  bool _showingNotes = false;
  bool _visitedNotes = false;

  @override
  void dispose() {
    _scroll.dispose();
    _notesFocus.dispose();
    super.dispose();
  }

  void _backFromNotes() {
    setState(() => _showingNotes = false);
    TuiBinding.of(context).addPostFrameCallback((_) {
      if (mounted) _notesFocus.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_showingNotes) {
      return MatrixDetails(
        command: 'rk init',
        title: 'Discovery notes',
        body: widget.notes.join('\n\n'),
        onBack: _backFromNotes,
      );
    }
    return MatrixShell(
      command: 'rk init',
      subtitle: 'Review release.toml',
      scrollFromActions: true,
      scrollController: _scroll,
      onEscape: () => widget.finish(InitReviewDecision.back),
      child: Text(widget.proposal),
      message: widget.needsIgnore
          ? 'Also adds .rk/ to .gitignore. Nothing is published.'
          : 'Nothing is published.',
      actions: [
        MatrixButton(
          text: '← Back',
          autofocus: !_visitedNotes,
          onPressed: () => widget.finish(InitReviewDecision.back),
        ),
        MatrixButton(
          text: 'Create release.toml',
          variant: ButtonVariant.success,
          onPressed: () => widget.finish(InitReviewDecision.write),
        ),
        MatrixButton(
          text: 'Cancel',
          onPressed: () => widget.finish(InitReviewDecision.cancel),
        ),
        if (widget.notes.isNotEmpty)
          MatrixButton(
            text: 'Discovery notes (${widget.notes.length})',
            focusNode: _notesFocus,
            onPressed: () => setState(() {
              _visitedNotes = true;
              _showingNotes = true;
            }),
          ),
      ],
    );
  }
}
