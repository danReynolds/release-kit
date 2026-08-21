import 'dart:io';

import '../../engine/diagnostic.dart';
import '../../engine/resolve.dart';
import '../../engine/targets.dart';
import '../../output/progress.dart';
import '../target_module.dart';

/// Owns the native Dart credential session used by pub.dev publication.
final class PubDevSession extends TargetSessionProvider {
  const PubDevSession();

  @override
  String get id => 'dart-pub';

  @override
  ProgressActivity get activity => CommonProgressActivities.checkingSignIn;

  @override
  Future<TargetReadinessOutcome> acquire(
    TargetReadinessContext context,
    ResolvedUnit unit,
    List<TargetPlan> targets,
  ) async {
    // An environment-backed token needs no second durable credential.
    if (await _tokenConfigured(context)) {
      return const TargetReady(note: 'token configured');
    }
    // Try quietly first so a current or refreshable session does not surface
    // provider chatter. A browser-assisted login must remain interactive.
    try {
      final quiet = await context.tools.run(
        'dart',
        const ['pub', 'login'],
        workingDirectory: context.git.root,
        timeout: const Duration(seconds: 20),
      );
      if (quiet.exitCode == 0) return const TargetReady(note: 'signed in');
    } on ProcessException {
      // The attached attempt below reports launcher failure to the operator.
    }

    int code;
    try {
      code = await context.runInteractive!(
        'dart',
        const ['pub', 'login'],
        workingDirectory: context.git.root,
      );
    } on ProcessException {
      code = -1;
    }
    if (code == 0) return const TargetReady(note: 'signed in');
    return TargetNotReady(
      Diagnostic(
        code: 'RK-PUB-007',
        message: 'dart pub login did not complete',
        remedy: 'Run dart pub login from a terminal, then re-run rk release '
            '${unit.name}. A successful login confirms a current session, '
            'not permission to publish every package.',
      ),
      unit: unit.name,
    );
  }

  /// Whether pub already has a token for pub.dev in this repository.
  Future<bool> _tokenConfigured(TargetReadinessContext context) async {
    try {
      final tokens = await context.tools.run(
        'dart',
        const ['pub', 'token', 'list'],
        workingDirectory: context.git.root,
      );
      if (!tokens.ok) return false;
      return tokens.stdout
          .split('\n')
          .map((line) => line.trim())
          .any((line) => line == _pubDevUrl || line == '$_pubDevUrl/');
    } on ProcessException {
      return false;
    }
  }

  @override
  Future<bool?> established(TargetReadinessContext context) async {
    if (await _tokenConfigured(context)) return true;
    return _sessionStored(context);
  }

  /// Whether this machine already holds a pub session, or null when rk
  /// cannot tell where one would be kept.
  static bool? _sessionStored(TargetReadinessContext context) {
    final credentials = _pubCredentialsFile(context.environment);
    if (credentials == null) return null;
    try {
      return credentials.existsSync();
    } on FileSystemException {
      return null;
    }
  }

  @override
  Future<String?> restore(TargetReadinessContext context) async {
    final out = await context.tools.run(
      'dart',
      const ['pub', 'logout'],
      workingDirectory: context.git.root,
    );
    return out.ok
        ? 'pub session cleared — it did not exist before this release'
        : 'pub session could not be cleared: ${out.summary}';
  }
}

const _pubDevUrl = 'https://pub.dev';

/// Where the pub client keeps the session `dart pub login` writes.
File? _pubCredentialsFile(Map<String, String> environment) {
  const name = 'dart/pub-credentials.json';
  if (Platform.isWindows) {
    final appData = environment['APPDATA'];
    return appData == null ? null : File('$appData/$name');
  }
  final home = environment['HOME'];
  if (Platform.isMacOS) {
    return home == null
        ? null
        : File('$home/Library/Application Support/$name');
  }
  final config =
      environment['XDG_CONFIG_HOME'] ?? (home == null ? null : '$home/.config');
  return config == null ? null : File('$config/$name');
}
