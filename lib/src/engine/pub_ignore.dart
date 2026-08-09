/// The subset of gitignore syntax rk understands, for reading `.pubignore`.
///
/// Why this exists: pub.dev exactness asks whether every file in the
/// source made it into the published archive, and a `.pubignore` legitimately
/// keeps files out. Without reading it, rk could only answer "some tracked
/// files are absent and I cannot say why" — an honest partial, and a useless
/// one for any package that uses the file. With it, a lean package is still
/// provable byte-for-byte.
///
/// The dangerous direction is over-matching: a pattern rk reads as "excluded"
/// silences a file that is genuinely missing from the archive. So this parser
/// is deliberately narrow and **declares what it does not understand** rather
/// than guessing. A file carrying any unsupported pattern yields
/// [unsupported], and the caller falls back to the honest partial — the same
/// answer rk gave before this existed. Refusing to reinterpret beats
/// reinterpreting wrongly.
class PubIgnore {
  PubIgnore._(this._rules, this.unsupported);

  /// Patterns rk could not translate. Non-empty means no verdict from this
  /// object may be trusted; the caller says so instead.
  final List<String> unsupported;

  final List<_Rule> _rules;

  bool get isComplete => unsupported.isEmpty;

  /// Parses `.pubignore` (or `.gitignore`) contents.
  static PubIgnore parse(String source) {
    final rules = <_Rule>[];
    final unsupported = <String>[];

    for (final raw in source.split('\n')) {
      // Trailing whitespace is not part of a pattern unless escaped, and an
      // escape is exactly the syntax this parser refuses to guess at.
      final line = raw.trimRight();
      if (line.isEmpty || line.startsWith('#')) continue;
      if (line.contains(r'\')) {
        unsupported.add(line);
        continue;
      }

      var pattern = line;
      final negated = pattern.startsWith('!');
      if (negated) pattern = pattern.substring(1);
      if (pattern.isEmpty) {
        unsupported.add(line);
        continue;
      }

      final directoryOnly = pattern.endsWith('/');
      if (directoryOnly) pattern = pattern.substring(0, pattern.length - 1);
      if (pattern.isEmpty) {
        unsupported.add(line);
        continue;
      }

      // A slash anywhere but the end anchors the pattern to the package root;
      // without one it matches at any depth.
      final anchored = pattern.startsWith('/') || pattern.contains('/');
      if (pattern.startsWith('/')) pattern = pattern.substring(1);

      final body = _translate(pattern);
      if (body == null) {
        unsupported.add(line);
        continue;
      }

      // A pattern that names a directory matches everything beneath it; one
      // that names a file matches the file, and also anything beneath it if
      // it turns out to be a directory — which is gitignore's rule too.
      final tail = directoryOnly ? '/.*' : r'(/.*)?';
      final head = anchored ? '' : r'(?:.*/)?';
      rules.add(_Rule(
        RegExp('^$head$body$tail\$'),
        negated: negated,
      ));
    }

    return PubIgnore._(rules, unsupported);
  }

  /// Whether [path] — package-relative, `/`-separated, no leading slash — is
  /// excluded. The last matching rule decides, as gitignore specifies.
  bool excludes(String path) {
    var excluded = false;
    for (final rule in _rules) {
      if (rule.matches.hasMatch(path)) excluded = !rule.negated;
    }
    return excluded;
  }

  /// One pattern as a regular expression, or null when it uses syntax this
  /// parser will not guess at.
  static String? _translate(String pattern) {
    final buffer = StringBuffer();
    var i = 0;
    while (i < pattern.length) {
      final char = pattern[i];
      switch (char) {
        case '*':
          final doubled = i + 1 < pattern.length && pattern[i + 1] == '*';
          if (!doubled) {
            // A single star stops at a separator.
            buffer.write('[^/]*');
            i++;
            break;
          }
          // `**` is only meaningful as a whole path segment: `**/a`, `a/**`,
          // `a/**/b`. Anywhere else gitignore treats it as a single star, and
          // rather than encode that subtlety this refuses the pattern.
          final before = i == 0 || pattern[i - 1] == '/';
          final afterAt = i + 2;
          final after = afterAt >= pattern.length || pattern[afterAt] == '/';
          if (!before || !after) return null;
          if (afterAt >= pattern.length) {
            // Trailing `**` — everything below.
            buffer.write('.*');
            i = afterAt;
          } else {
            // `**/` — zero or more directories.
            buffer.write('(?:.*/)?');
            i = afterAt + 1;
          }
        case '?':
          buffer.write('[^/]');
          i++;
        case '[':
          final close = pattern.indexOf(']', i + 1);
          if (close < 0) return null;
          var body = pattern.substring(i + 1, close);
          if (body.isEmpty) return null;
          if (body.startsWith('!')) body = '^${body.substring(1)}';
          // Character classes pass through, minus the separator, which no
          // gitignore wildcard may cross.
          if (body.contains('/')) return null;
          buffer.write('[$body]');
          i = close + 1;
        case '/':
          buffer.write('/');
          i++;
        default:
          buffer.write(RegExp.escape(char));
          i++;
      }
    }
    return buffer.toString();
  }
}

class _Rule {
  _Rule(this.matches, {required this.negated});
  final RegExp matches;
  final bool negated;
}
