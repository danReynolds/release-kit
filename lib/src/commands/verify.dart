import '../engine/output.dart';
import '../engine/registry.dart';
import '../engine/resolve.dart';
import '../engine/verdict.dart';
import '../engine/version.dart';

/// Proves a published release against what it claims, using no local state.
///
/// Anyone with a clone can run it, at any later date. What rk cannot know it
/// says so, rather than omitting the line and letting silence read as proof.
class VerifyCommand {
  VerifyCommand({
    required this.resolution,
    required this.registry,
    required this.output,
  });

  final Resolution resolution;
  final RegistryReader registry;
  final Output output;

  Future<int> run({String? only}) async {
    final units = only == null
        ? resolution.units
        : resolution.units.where((u) => u.name == only).toList();

    if (units.isEmpty) {
      output.line('no unit named "$only"', mark: Mark.blocked);
      return ExitCodes.usage;
    }

    var failed = false;
    for (final unit in units) {
      failed = await _unit(unit) || failed;
    }
    return failed ? ExitCodes.refused : ExitCodes.ok;
  }

  Future<bool> _unit(ResolvedUnit unit) async {
    output.blank();

    final checks = <_Check>[];
    for (final project in unit.projects) {
      if (project.channels.contains('pub.dev')) {
        checks.add(await _registryCheck(project));
      }
      for (final channel in project.channels) {
        if (channel == 'pub.dev') continue;
        checks.add(
          _Check(
            label: channel,
            state: _CheckState.notChecked,
            note: 'not built yet',
          ),
        );
      }
    }

    final failures = checks.where((c) => c.state == _CheckState.failed);
    output.line(
      '${unit.name} ${unit.version}',
      note: failures.isEmpty ? 'verified' : '${failures.length} failed',
      mark: failures.isEmpty ? Mark.done : Mark.blocked,
    );

    for (final check in checks) {
      output.line(
        check.label,
        depth: 1,
        mark: switch (check.state) {
          _CheckState.passed => Mark.done,
          _CheckState.failed => Mark.blocked,
          _CheckState.notChecked => Mark.none,
        },
        note: check.note,
      );
    }

    if (failures.isNotEmpty) {
      output.blank();
      output.say('what rk read is public and cannot be edited. the only way '
          'forward is the next version.');
    }
    return failures.isNotEmpty;
  }

  Future<_Check> _registryCheck(ResolvedProject project) async {
    final Inspection inspection;
    try {
      inspection = await registry.inspect(project.name, project.version);
    } on Object catch (error) {
      return _Check(
        label: 'pub.dev',
        state: _CheckState.notChecked,
        note: 'could not be read: $error',
      );
    }

    return switch (inspection.verdict) {
      Verdict.exact => _Check(
          label: 'pub.dev',
          state: _CheckState.passed,
          note: '${project.name} ${project.version} · ${inspection.detail}',
        ),
      Verdict.absent => _Check(
          label: 'pub.dev',
          state: _CheckState.failed,
          note: '${project.name} ${project.version} is not published',
        ),
      Verdict.conflict => _Check(
          label: 'pub.dev',
          state: _CheckState.failed,
          note: inspection.detail ?? 'differs from this source',
        ),
      Verdict.unknown => _Check(
          label: 'pub.dev',
          state: _CheckState.notChecked,
          note: inspection.detail,
        ),
    };
  }
}

enum _CheckState { passed, failed, notChecked }

class _Check {
  _Check({required this.label, required this.state, this.note});
  final String label;
  final _CheckState state;
  final String? note;
}

/// Provenance a release carries, assembled from public reality rather than
/// records rk keeps.
class Provenance {
  Provenance({
    required this.publishedAt,
    required this.commit,
    required this.signer,
  });

  final DateTime? publishedAt;

  /// Null when nothing binds the published version to a commit — which is the
  /// honest answer for a release made without a tag.
  final String? commit;

  final String? signer;

  /// What rk cannot know, stated rather than omitted.
  List<String> get unknowable => [
        if (commit == null)
          'which commit produced it — no tag records that',
        if (signer == null) 'who authorised it — the tag is unsigned or absent',
      ];
}

/// A version rk would report as the latest public one.
Version? latestPublished(RegistryPackage? package) => package?.latest?.version;
