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
  String message = 'Review your choices before creating release.toml.';
  bool showPrivate = false;
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
  Future<void>? _running;
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
    });
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
        requestExit();
        await _running;
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

class InitScreen extends StatelessWidget {
  const InitScreen(this.model, {super.key});
  final InitPicker model;
  @override
  Widget build(BuildContext context) {
    context.listen(model);
    return MatrixShell(
      command: 'rk init',
      count: '${model.visible.length} packages',
      subtitle: 'Choose the outputs for each package.',
      message: model.message,
      onEscape: () => model.finish(null),
      child: ChoiceMatrix(
        columns: ReleaseChoice.values.map((c) => c.selectorLabel).toList(),
        rows: [for (final i in model.visible) _row(i)],
      ),
      actions: [
        const Text('↑↓←→ move · Space toggle', style: mutedText),
        if (model.plan.candidates.any((c) => c.vetoesRegistry))
          Button(
            text: model.showPrivate
                ? 'Hide private packages'
                : 'Show private packages',
            autofocus: model.visible.isEmpty,
            onPressed: model.togglePrivate,
          ),
        Button(text: 'Esc Cancel', onPressed: () => model.finish(null)),
        Button(
          text: 'Review configuration →',
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
            autofocus:
                index == model.visible.first &&
                choice == ReleaseChoice.values.first,
            onPressed: () => model.toggle(index, choice),
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

class InitReviewScreen extends StatelessWidget {
  const InitReviewScreen(
    this.proposal,
    this.needsIgnore,
    this.finish, {
    super.key,
  });
  final String proposal;
  final bool needsIgnore;
  final void Function(InitReviewDecision) finish;

  @override
  Widget build(BuildContext context) => MatrixShell(
    command: 'rk init',
    subtitle: 'Review release.toml',
    onEscape: () => finish(InitReviewDecision.back),
    child: Text(proposal),
    message: needsIgnore
        ? 'Also adds .rk/ to .gitignore. Nothing is published.'
        : 'Nothing is published.',
    actions: [
      Button(
        text: '← Back',
        autofocus: true,
        onPressed: () => finish(InitReviewDecision.back),
      ),
      Button(
        text: 'Create release.toml',
        variant: ButtonVariant.success,
        onPressed: () => finish(InitReviewDecision.write),
      ),
      Button(
        text: 'Cancel',
        onPressed: () => finish(InitReviewDecision.cancel),
      ),
    ],
  );
}
