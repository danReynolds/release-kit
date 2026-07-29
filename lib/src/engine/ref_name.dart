/// Why git would refuse [name] as a tag, or null when it would accept it.
///
/// rk checks this before doing any work rather than discovering it at tag time:
/// a name git will not take is a configuration mistake, and a configuration
/// mistake found after three archives have been built and notarized has cost
/// the author a release cycle to learn something readable from the file alone.
///
/// These are git-check-ref-format's rules for a single-component ref under
/// `refs/tags/`, kept in the order the manual states them.
String? refNameIssue(String name) {
  if (name.isEmpty) return 'it is empty';
  if (name == '@') return 'a lone "@" is reserved';

  for (final component in name.split('/')) {
    if (component.isEmpty) return 'it has an empty path component';
    if (component.startsWith('.')) return 'a component cannot begin with "."';
    if (component.endsWith('.lock')) return 'a component cannot end in ".lock"';
  }

  if (name.endsWith('.')) return 'it cannot end with "."';
  if (name.contains('..')) return 'it cannot contain ".."';
  if (name.contains('@{')) return 'it cannot contain "@{"';

  for (final rune in name.runes) {
    if (rune <= 0x20 || rune == 0x7f) {
      return rune == 0x20
          ? 'it cannot contain a space'
          : 'it cannot contain control characters';
    }
    const forbidden = '~^:?*[\\';
    if (forbidden.contains(String.fromCharCode(rune))) {
      return 'it cannot contain "${String.fromCharCode(rune)}"';
    }
  }

  return null;
}
