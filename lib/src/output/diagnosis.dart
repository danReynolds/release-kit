import 'dart:io';

import 'report.dart';

/// Evidence about a run that did not end cleanly.
///
/// Reality is rk's database and reality records what exists, not why an attempt
/// failed — so the one thing an operator needs after a bad run is the one thing
/// no destination can tell them. This writes it down.
///
/// rk never reads it back. That is what keeps it honest: nothing rk decides
/// later can depend on a file a person is free to delete, so deleting it is
/// always safe and the directory can never become the state store rk does not
/// have.
class Diagnosis {
  /// Whether a failed run is allowed to leave repository-local evidence.
  ///
  /// `rk plan` is an unusually strict read-only surface: even an rk bug must
  /// not make its "nothing changed" contract false. Other commands retain a
  /// crash because the stack is otherwise lost, and retain an ordinary
  /// failure only after the run began acting.
  static bool shouldWrite({
    required String command,
    required bool acted,
    required bool crashed,
  }) =>
      command != 'plan' && (acted || crashed);

  /// Writes [report] and [attachments] under `<root>/.rk/diagnosis/<stamp>/`,
  /// returning where they went so the operator can be told.
  ///
  /// [stamp] distinguishes runs and is passed in rather than taken from the
  /// clock, so the caller decides how runs are named and a test can name one.
  static String write(
    String root, {
    required String stamp,
    required Report report,
    required int exit,
    Map<String, String> attachments = const {},
  }) {
    final at = '$root/.rk/diagnosis/$stamp';
    // The report already carries the resolved checklist, each step's verdict
    // and duration, and every problem, so it is the diagnosis rather than a
    // summary of one.
    _put('$at/run.json', report.encode(exit: exit));
    attachments.forEach((name, contents) => _put('$at/$name', contents));
    return at;
  }

  static void _put(String path, String contents) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(contents);
  }
}
