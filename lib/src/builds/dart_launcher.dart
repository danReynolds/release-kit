/// A native launcher follows its installed location (including a Homebrew
/// symlink), never PATH or cwd. execv preserves signals and exit status.
String dartLauncherSource(String executable) => '''
#include <mach-o/dyld.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
  char image[PATH_MAX], root[PATH_MAX], runtime[PATH_MAX], module[PATH_MAX];
  uint32_t size = sizeof(image);
  if (_NSGetExecutablePath(image, &size) != 0 || realpath(image, root) == NULL)
    goto failed;
  char *slash = strrchr(root, '/');
  if (slash == NULL) goto failed;
  *slash = '\\0';
  int r = snprintf(runtime, sizeof(runtime), "%s/lib/$executable/dartaotruntime", root);
  int m = snprintf(module, sizeof(module), "%s/lib/$executable/app.aot", root);
  if (r < 0 || r >= sizeof(runtime) || m < 0 || m >= sizeof(module)) goto failed;
  char **args = calloc((size_t)argc + 2, sizeof(char *));
  if (args == NULL) goto failed;
  args[0] = runtime;
  args[1] = module;
  for (int i = 1; i < argc; i++) args[i + 1] = argv[i];
  execv(runtime, args);
  free(args);
failed:
  fputs("$executable: could not start the installed application\\n", stderr);
  return 126;
}
''';
