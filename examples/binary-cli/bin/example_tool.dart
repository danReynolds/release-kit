/// Prints its version, which is what the build step checks the binary against.
void main(List<String> args) {
  if (args.contains('--version')) print('2.1.0');
}
