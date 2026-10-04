import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../rk_process.dart';
import 'pub_registry_fixture.dart';

/// Runs RK's shared command entry point and the unchanged Dart SDK frontend.
///
/// The test entry point explicitly composes a loopback Pub endpoint. Every native
/// command uses the same local hosted URL and isolated credentials/cache. A proxy
/// rejects every non-loopback HTTP(S) request; it never forwards connections.
///
/// Requires Python 3 on POSIX only to establish private process groups before
/// exec. It does not interpret package data, emulate commands or access networks.
final class NativePublicationFixture {
  NativePublicationFixture._(this.root, this.repository);

  final Directory root;
  final Directory repository;
  late final PubRegistryFixture registry;
  HttpServer? _server;
  HttpServer? _proxy;
  late final String _dart;
  late final Map<String, String> environment;
  final List<String> connections = [];
  final Set<_Child> _children = {};
  bool _closed = false;

  static const _tokenVariable = 'RK_LOCAL_PUBLICATION_TOKEN';
  static final _project = Directory.current.absolute.path;
  static final _python = _executableOnPath('python3');

  static Future<NativePublicationFixture> create() async {
    if (!Platform.isLinux && !Platform.isMacOS) {
      throw UnsupportedError(
        'Native publication qualification requires POSIX.',
      );
    }
    final root = Directory.systemTemp.createTempSync('rk-publication-');
    final repository = Directory('${root.path}/repository')..createSync();
    final fixture = NativePublicationFixture._(root, repository);
    try {
      await fixture._initialize();
      return fixture;
    } on Object {
      await fixture.close();
      rethrow;
    }
  }

  Future<void> _initialize() async {
    _dart = File(
      Platform.environment['RK_NATIVE_DART'] ?? Platform.resolvedExecutable,
    ).resolveSymbolicLinksSync();
    final sdkBin = File(_dart).parent.path;
    final server = _server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    registry = PubRegistryFixture(
      Directory('${root.path}/registry'),
      origin: 'http://127.0.0.1:${server.port}',
    );
    server.listen(registry.handle, onError: _transportError);
    final proxy = _proxy = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    proxy.listen(_denyExternal, onError: _transportError);
    for (final directory in ['home', 'config', 'cache', 'tmp']) {
      Directory('${root.path}/$directory').createSync();
    }
    environment = Map.unmodifiable({
      'PATH': '$sdkBin:/usr/bin:/bin:/usr/sbin:/sbin',
      'HOME': '${root.path}/home',
      'XDG_CONFIG_HOME': '${root.path}/config',
      'PUB_CACHE': '${root.path}/cache',
      'PUB_HOSTED_URL': registry.origin,
      'TMPDIR': '${root.path}/tmp',
      'LANG': 'en_US.UTF-8',
      'CI': 'true',
      'DART_DISABLE_ANALYTICS': '1',
      'PUB_ENVIRONMENT': 'rk-publication-qualification',
      'PUB_MAX_HTTP_RETRIES': '1',
      'http_proxy': 'http://127.0.0.1:${proxy.port}',
      'https_proxy': 'http://127.0.0.1:${proxy.port}',
      // Native discovery creates additional loopback servers within RK.
      'no_proxy': '127.0.0.1,localhost,::1',
      'GIT_CONFIG_NOSYSTEM': '1',
      'GIT_CONFIG_GLOBAL': '/dev/null',
      'GIT_TERMINAL_PROMPT': '0',
      _tokenVariable: registry.token,
    });
    final source = Directory('$_project/examples/local-publication');
    for (final entry in source.listSync(recursive: true)) {
      if (entry is! File) continue;
      final relative = entry.path.substring(source.path.length + 1);
      final target = File('${repository.path}/$relative');
      target.parent.createSync(recursive: true);
      entry.copySync(target.path);
    }
    for (final arguments in [
      ['init', '--quiet'],
      ['config', 'user.name', 'RK publication fixture'],
      ['config', 'user.email', 'rk@example.test'],
      ['add', '-A'],
      ['commit', '--quiet', '-m', 'publication fixture'],
    ]) {
      _require(
        await runProcess('git', arguments),
        'initializing source fixture',
      );
    }
    _require(
      await runDart([
        'pub',
        'token',
        'add',
        registry.origin,
        '--env-var',
        _tokenVariable,
      ]),
      'registering isolated native Pub credentials',
    );
  }

  Future<void> _denyExternal(HttpRequest request) async {
    connections.add('${request.method} ${request.uri}');
    try {
      request.response.statusCode = HttpStatus.forbidden;
      await request.response.close();
    } on Object catch (error, stack) {
      _transportError(error, stack);
    }
  }

  void _transportError(Object error, StackTrace stack) {
    // Deliberate process interruption and lost responses can disconnect clients.
    // Native command assertions still observe failures; programming errors remain
    // visible instead of being mistaken for routine transport shutdown.
    if (error is SocketException || error is HttpException) return;
    Error.throwWithStackTrace(error, stack);
  }

  /// [interruptWhen] ends this owned process group at an observed test barrier.
  /// It returns 130 and leaves the stage/registry intact for a fresh-process retry.
  /// Completing a barrier after the command has settled has no effect.
  Future<Run> rk(
    List<String> arguments, {
    String? workingDirectory,
    Future<void>? interruptWhen,
  }) async {
    final result = await runDart(
      [
        '--packages=$_project/.dart_tool/package_config.json',
        '$_project/test/support/local_pub_rk.dart',
        ...arguments,
      ],
      workingDirectory: workingDirectory,
      timeout: const Duration(minutes: 3),
      interruptWhen: interruptWhen,
    );
    return Run(
      code: result.exitCode,
      stdout: result.stdout as String,
      stderr: result.stderr as String,
    );
  }

  Future<ProcessResult> runDart(
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    Duration timeout = const Duration(seconds: 90),
    Future<void>? interruptWhen,
  }) => runProcess(
    _dart,
    arguments,
    workingDirectory: workingDirectory,
    environment: environment,
    timeout: timeout,
    interruptWhen: interruptWhen,
  );

  Future<ProcessResult> runProcess(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    Duration timeout = const Duration(seconds: 90),
    Future<void>? interruptWhen,
  }) async {
    if (_closed) throw StateError('publication fixture is closed');
    // Only cache isolation is adjustable by consumers; never permit a caller to
    // disable the fixture's routing or import real credentials into a child.
    if (environment?.keys.any((key) => key != 'PUB_CACHE') ?? false) {
      throw ArgumentError('only PUB_CACHE may vary for a fixture consumer');
    }
    return _execute(
      executable,
      arguments,
      {...this.environment, ...?environment},
      workingDirectory: workingDirectory,
      timeout: timeout,
      interruptWhen: interruptWhen,
    );
  }

  Future<ProcessResult> _execute(
    String executable,
    List<String> arguments,
    Map<String, String> childEnvironment, {
    String? workingDirectory,
    Duration timeout = const Duration(seconds: 90),
    Future<void>? interruptWhen,
  }) async {
    final process = await Process.start(
      _python,
      [
        '-c',
        'import os, sys; os.setsid(); '
            'os.execvpe(sys.argv[1], sys.argv[1:], os.environ)',
        executable,
        ...arguments,
      ],
      workingDirectory: workingDirectory ?? repository.path,
      environment: childEnvironment,
      includeParentEnvironment: false,
    );
    final child = _Child(process);
    _children.add(child);
    final completion = Completer<ProcessResult>();
    var accepting = true;
    unawaited(
      child.result.then(
        (result) {
          if (!accepting) return;
          accepting = false;
          completion.complete(result);
        },
        onError: (Object error, StackTrace stack) {
          if (!accepting) return;
          accepting = false;
          completion.completeError(error, stack);
        },
      ),
    );
    if (interruptWhen != null) {
      unawaited(
        interruptWhen.then(
          (_) {
            // A late barrier must never signal a PID that has already completed.
            // Claim the outcome before stop closes streams and completes result.
            if (!accepting) return;
            accepting = false;
            completion.complete(() async {
              await child.stop();
              return ProcessResult(
                process.pid,
                130,
                child.output.text,
                '${child.errors.text}\nFixture interrupted at its observed barrier.',
              );
            }());
          },
          onError: (Object error, StackTrace stack) {
            if (!accepting) return;
            accepting = false;
            completion.completeError(error, stack);
          },
        ),
      );
    }
    try {
      return await completion.future.timeout(
        timeout,
        onTimeout: () async {
          accepting = false;
          await child.stop();
          return ProcessResult(
            process.pid,
            124,
            child.output.text,
            '${child.errors.text}\nFixture process exceeded $timeout.',
          );
        },
      );
    } finally {
      accepting = false;
      child.killGroup();
      _children.remove(child);
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await Future.wait(_children.map((child) => child.stop()));
    await _proxy?.close(force: true);
    await _server?.close(force: true);
    if (root.existsSync()) root.deleteSync(recursive: true);
  }
}

String _executableOnPath(String name) {
  for (final directory in (Platform.environment['PATH'] ?? '').split(':')) {
    if (directory.isEmpty) continue;
    final file = File('$directory/$name');
    if (file.existsSync()) return file.resolveSymbolicLinksSync();
  }
  throw StateError('Native publication qualification requires $name on PATH.');
}

void _require(ProcessResult result, String purpose) {
  if (result.exitCode != 0) {
    throw StateError(
      '$purpose failed (${result.exitCode}):\n${result.stdout}\n${result.stderr}',
    );
  }
}

final class _Child {
  _Child(this.process) {
    output = _Capture(process.stdout);
    errors = _Capture(process.stderr);
    unawaited(process.stdin.close());
    result = Future.wait<Object?>([process.exitCode, output.done, errors.done])
        .then(
          (values) => ProcessResult(
            process.pid,
            values.first as int,
            output.text,
            errors.text,
          ),
        );
  }
  final Process process;
  late final _Capture output;
  late final _Capture errors;
  late final Future<ProcessResult> result;

  void killGroup() {
    // Every launch creates a private POSIX session before exec. A background
    // descendant retains this group even if its original parent already exited.
    Process.killPid(-process.pid, ProcessSignal.sigkill);
  }

  Future<void> stop() async {
    killGroup();
    // Covers a timeout during Python startup before setsid has completed.
    process.kill(ProcessSignal.sigkill);
    await Future.wait([output.cancel(), errors.cancel()]);
    try {
      await process.exitCode.timeout(const Duration(seconds: 2));
    } on TimeoutException {
      // Capture cancellation already bounds the caller.
    }
  }
}

final class _Capture {
  _Capture(Stream<List<int>> stream) {
    _subscription = stream.listen(
      (chunk) {
        final remaining = 1024 * 1024 - _bytes.length;
        if (remaining > 0) _bytes.addAll(chunk.take(remaining));
        if (chunk.length > remaining) _truncated = true;
      },
      onDone: _complete,
      onError: (Object _) => _complete(),
    );
  }
  final List<int> _bytes = [];
  final Completer<void> _done = Completer<void>();
  late final StreamSubscription<List<int>> _subscription;
  bool _truncated = false;
  Future<void> get done => _done.future;
  String get text =>
      '${utf8.decode(_bytes, allowMalformed: true)}${_truncated ? '\n[fixture output truncated]' : ''}';
  void _complete() {
    if (!_done.isCompleted) _done.complete();
  }

  Future<void> cancel() async {
    await _subscription.cancel();
    _complete();
  }
}
