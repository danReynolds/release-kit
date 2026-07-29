import 'report.dart';
import 'workspace.dart';

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
  /// Writes [report] and [attachments] under `diagnosis/<stamp>/`, returning
  /// where they went so the operator can be told.
  ///
  /// [stamp] distinguishes runs and is passed in rather than taken from the
  /// clock, so the caller decides how runs are named and a test can name one.
  static String write(
    Workspace workspace, {
    required String stamp,
    required Report report,
    required int exit,
    Map<String, String> attachments = const {},
  }) {
    final at = 'diagnosis/$stamp';
    // The report already carries the resolved checklist, each step's verdict
    // and duration, and every problem, so it is the diagnosis rather than a
    // summary of one.
    workspace.put('$at/run.json', report.encode(exit: exit));
    attachments.forEach((name, contents) {
      workspace.put('$at/$name', contents);
    });
    return workspace.describe(at);
  }
}
