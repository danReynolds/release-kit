import '../engine/tools.dart';
import 'model.dart';

/// Installation capability lives beside a provider, not in UI/release lifecycle.
abstract class InstallationProvider {
  InstallationSource get source;
  Future<SourceInspection> inspect(ExecutableProject project);
  Future<Installation> install(
    ExecutableProject project,
    void Function(String) progress,
  );
  Future<void> uninstall(ExecutableProject project, Installation installation);
}

Future<ToolResult> checked(
  Tools tools,
  String executable,
  List<String> arguments, {
  String? directory,
  Map<String, String>? environment,
}) async {
  final result = await tools.run(
    executable,
    arguments,
    workingDirectory: directory,
    environment: environment,
    timeout: const Duration(minutes: 10),
  );
  if (!result.ok) {
    throw InstallationFailure(
      result.summary,
      'Resolve the provider error, then check rk use --list before retrying.',
    );
  }
  return result;
}
