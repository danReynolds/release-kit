import '../engine/tools.dart';
import 'model.dart';
import 'provider.dart';
import 'store.dart';

/// A child cannot edit its parent's environment. Fish can persist a universal
/// path which other fish sessions pick up at their next prompt. Other shells
/// get an explicit command; rk never rewrites a startup file behind their back.
class ShellRouting {
  ShellRouting(this.store, this.tools, this.environment);
  final InstallationStore store;
  final Tools tools;
  final Map<String, String> environment;

  Future<String?> ensure(ExecutableProject project) async {
    if (store.routingProblems(project, environment).isEmpty) return null;
    final shell = environment['SHELL'] ?? '';
    if (shell.split('/').last == 'fish' && shell.startsWith('/')) {
      try {
        await checked(tools, shell, [
          '-c',
          r'fish_add_path --universal --move --prepend -- $argv[1]',
          store.bin,
        ], environment: environment);
        return 'Ready at the next prompt.';
      } on InstallationFailure catch (error) {
        return 'Selected, but fish PATH setup failed: ${error.message}. Run: fish_add_path --move --prepend ${shellQuote(store.bin)}';
      }
    }
    return 'Selection saved. Put the managed commands first in this shell: export PATH=${shellQuote(store.bin)}:"\$PATH"';
  }
}
