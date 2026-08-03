import 'dart:convert';
import 'dart:io';

import '../builds/capability.dart';
import '../engine/changelog.dart';
import '../engine/checklist.dart';
import '../engine/diagnostic.dart';
import '../engine/git.dart';
import '../engine/output.dart';
import '../engine/compare.dart';
import '../engine/inspect.dart';
import '../engine/registry.dart';
import '../engine/resolve.dart';
import '../engine/source_tree.dart';
import '../engine/tools.dart';
import '../engine/identity.dart';
import '../engine/verdict.dart';
import '../engine/version.dart';
import '../engine/workspace.dart';
import 'binary_chain.dart';

/// Executes a release: inspect, act, verify, one step at a time.
///
/// Every step is decided from its own inspection of reality, never from what a
/// previous step left behind — which is what makes re-running the resume, and
/// what will let CI split the steps across machines later.
class ReleaseCommand {
  ReleaseCommand({
    required this.resolution,
    required this.tree,
    required this.git,
    required this.registry,
    required this.inspector,
    required this.comparator,
    required this.tools,
    required this.output,
    required this.confirm,
    this.dryRun = false,
    this.rehearse = false,
    Future<void> Function(Duration)? wait,
    HostCapabilities? capabilities,
  })  : _wait = wait ?? _sleep,
        _capabilities = capabilities;

  static Future<void> _sleep(Duration duration) =>
      Future<void>.delayed(duration);

  final Resolution resolution;
  final SourceTree tree;
  final GitState git;
  final RegistryReader registry;

  /// Reads reality for a step. The same one `status` uses, so the two verbs
  /// cannot answer the same question differently — release grew its own copy
  /// once, and it answered `absent` by default for every kind it did not name.
  final Inspector inspector;

  /// The same comparator `verify` wears. The post-publish check is a
  /// verification, and a second comparison implementation would be the
  /// two-inspectors drift over again.
  final Comparator comparator;

  /// Waits, injectable so a test proves the polling without living it.
  final Future<void> Function(Duration) _wait;

  /// How long the confirming read chases a version the registry has accepted
  /// but does not list yet, and how often it asks. Bounded: an unlisted
  /// version after a minute is worth a human's eyes, not an infinite loop.
  static const confirmDeadline = Duration(seconds: 60);
  static const confirmInterval = Duration(seconds: 5);

  final Tools tools;
  final Output output;

  /// Asks the operator to type the version. Returns what they typed, or null
  /// when there is nobody to ask.
  final Future<String?> Function(String prompt)? confirm;

  /// What this host can produce — injectable so a drive can span platforms
  /// the test machine does not have. Null detects lazily, once.
  HostCapabilities? _capabilities;
  HostCapabilities get capabilities =>
      _capabilities ??= HostCapabilities.detect();

  /// Show what would happen and stop before the first effect.
  final bool dryRun;

  /// Run every local step for real and stop before anything public.
  ///
  /// The rehearsal exists so an expired certificate or a broken notarization
  /// is discovered on a quiet afternoon, not at minute forty of an announced
  /// release. Public steps — the tag, every publish — are inspected but
  /// never acted on, and nothing is authorized because nothing permanent
  /// happens.
  final bool rehearse;

  Future<int> run({String? only}) async {
    final units = only == null
        ? resolution.units
        : resolution.units.where((u) => u.name == only).toList();

    if (units.isEmpty) {
      output.problem(
        Diagnostic(
          code: 'RK-CLI-003',
          message: 'no unit named "$only"',
          remedy: 'this repository releases: '
              '${resolution.units.map((u) => u.name).join(', ')}',
        ),
      );
      return ExitCodes.usage;
    }
    if (units.length > 1) {
      output.problem(
        Diagnostic(
          code: 'RK-CLI-004',
          message: 'name the unit to release',
          remedy: 'this repository releases several, and a release is of one: '
              '${units.map((u) => u.name).join(', ')}',
        ),
      );
      return ExitCodes.usage;
    }

    return _release(units.single);
  }

  Future<int> _release(ResolvedUnit unit) async {
    // Refuse anything rk cannot finish here, before doing any work rather
    // than at the last step.
    final refusal = _refuseIfUnfinishable(unit);
    if (refusal != null) {
      output.problem(refusal);
      return ExitCodes.refused;
    }

    // Validate independently: rk cannot assume status was run, and its
    // findings may be stale by now.
    final problems = Diagnostics();
    _validate(unit, problems);
    if (problems.isNotEmpty) {
      output.halt(HaltKind.beforeActing);
      output.problems(problems.found);
      return ExitCodes.refused;
    }

    final checklist = Checklist.derive(unit, resolution, problems);
    if (problems.isNotEmpty) {
      output.halt(HaltKind.beforeActing);
      output.problems(problems.found);
      return ExitCodes.refused;
    }
    final states = <String, Inspection>{};

    // Inspect everything first, so the operator is asked about what is
    // actually left rather than about the whole checklist.
    for (final step in checklist.steps) {
      states[step.id] = await inspector.inspect(step, unit);
    }

    // Everything inspected is recorded before anything is decided, so a halt
    // is never prose-only: a caller gets the checklist with verdicts keyed by
    // step id, whatever happens next.
    for (final step in checklist.steps) {
      final state = states[step.id]!;
      output.step(
        step,
        verdict: state.verdict,
        detail: state.detail,
        evidence: state.evidence,
        show: false,
      );
    }

    // Release validates independently rather than trusting status — and the
    // top-ranked failure, publishing a back-version, was checked only by the
    // verb that does not act.
    await inspector.monotonicity(unit, problems);
    inspector.tagGuards(unit, checklist, states).forEach(problems.report);
    await _refuseFirstPublish(unit, problems);
    if (problems.isNotEmpty) {
      output.halt(HaltKind.beforeActing);
      output.problems(problems.found);
      return ExitCodes.refused;
    }

    // What blocks, before anything acts. Local steps answer unknown by
    // design — they are the work this run does — so unknown halts only where
    // the state was supposed to be readable: a destination rk could not reach
    // is not permission to publish to it. The one absence that blocks is a
    // prerequisite, and it blocks as something re-running fixes once the
    // other unit has shipped.
    final halting = checklist.steps
        .where((s) => Inspector.blocks(s, states[s.id]!))
        .toList();
    if (halting.isNotEmpty) {
      final first = halting.first;
      final state = states[first.id]!;
      output.halt(
        state.verdict == Verdict.conflict
            ? HaltKind.unfixableByRerun
            : HaltKind.beforeActing,
      );
      // A problem, not a bare line: the same call records it, so the halt a
      // person reads is the halt a caller gets.
      output.problem(
        Diagnostic(
          code: 'RK-REL-001',
          message: '${first.summary}: '
              '${state.detail ?? state.verdict.name}',
          remedy: state.evidence.isEmpty
              ? null
              : state.evidence.entries
                  .map((e) => '${e.key}: ${e.value}')
                  .join('\n'),
        ),
      );
      return ExitCodes.refused;
    }

    final remaining =
        checklist.steps.where((s) => !states[s.id]!.isExact).toList();

    if (remaining.isEmpty) {
      output.line(
        '${unit.name} ${unit.version}',
        mark: Mark.done,
        note: 'already released',
      );
      // Existence is confirmed here, not byte identity — that proof is one
      // command away and worth pointing at.
      output.next('rk verify ${unit.name}');
      return ExitCodes.ok;
    }

    // The publish preflight, before anything acts and inside --dry-run: pub's
    // own validation and the consumer resolve are both read-only, and running
    // them inside the publish step meant the first real run discovered a
    // validation refusal only after the signed tag was public.
    for (final step in checklist.steps) {
      if (step.kind != StepKind.publishRegistry) continue;
      if (states[step.id]!.isExact) continue;
      final project = unit.projects.firstWhere((p) => p.name == step.project);
      if (!await _publishPreflight(project)) return ExitCodes.refused;
    }

    // The signing baseline, resolved here for the same reason: it is a
    // read, and reading it inside the sign step meant an unreadable baseline
    // surfaced after the tag was public — as a crash claiming a bug in rk.
    String? publishedRequirement;
    if (checklist.steps
        .any((s) => s.kind == StepKind.sign && !states[s.id]!.isExact)) {
      final baseline = await _signingBaseline(unit);
      if (!baseline.ok) return ExitCodes.refused;
      publishedRequirement = baseline.requirement;
    }

    output.heading('${unit.name} ${unit.version} → '
        '${_channels(unit).join(', ')}');
    output.blank();

    for (final step in checklist.steps) {
      final state = states[step.id]!;
      output.step(
        step,
        mark: state.isExact ? Mark.satisfied : Mark.none,
        verdict: state.verdict,
        detail: state.detail,
        note: state.isExact ? (state.detail ?? 'already done') : null,
        depth: 0,
      );
    }

    if (dryRun) {
      output.blank();
      output.say('nothing was started.');
      return ExitCodes.ok;
    }

    if (!rehearse && !await _authorize(unit, remaining)) {
      return ExitCodes.refused;
    }

    output.blank();
    var rehearsed = 0;
    for (final step in checklist.steps) {
      if (states[step.id]!.isExact) continue;
      if (rehearse && step.isPublic) {
        rehearsed++;
        output.step(
          step,
          verdict: states[step.id]!.verdict,
          note: 'rehearsal — not touched',
        );
        continue;
      }
      // From here on the world may change, which is what makes a failure
      // worth recording evidence about. A rehearsal's local acts count too.
      output.report.acted = true;
      final ok = await _act(step, unit, publishedRequirement);
      // The act's answer supersedes the inspection's: without this, the
      // document of a failed run said `absent` about a tag that was already
      // public — rk acted, and the JSON said nothing had.
      output.step(
        step,
        verdict: ok ? Verdict.exact : Verdict.unknown,
        detail: ok ? 'done this run' : 'the act did not complete',
        show: false,
      );
      if (!ok) {
        // Every halt opens with its sentence. The specific ones — a sign
        // mismatch, a release read back wrong — were recorded where they
        // were diagnosed; everything else stopped partway through local
        // work, with a tag possibly already public, so neither "nothing
        // changed" nor "lost sight of the result" would be true.
        if (!output.report.halted) output.halt(HaltKind.stoppedPartway);
        return ExitCodes.refused;
      }
    }

    if (rehearse) {
      output.blank();
      output.line(
        '${unit.name} ${unit.version} rehearsed',
        mark: Mark.done,
        note: '$rehearsed public steps untouched',
      );
      output.say('every local step ran for real; nothing public changed. '
          'The release itself is: rk release ${unit.name}');
      return ExitCodes.ok;
    }

    output.blank();
    output.line('${unit.name} ${unit.version} released', mark: Mark.done);
    for (final project in unit.projects) {
      if (!project.channels.contains('pub.dev')) continue;
      output.say(
          'pub.dev/packages/${project.name}/versions/'
          '${project.version}',
          depth: 1);
    }
    return ExitCodes.ok;
  }

  /// A package that has never existed is not published by rk.
  ///
  /// The first publish is a ceremony — accepting pub.dev's terms, choosing a
  /// publisher — and running it under --force from an executor would perform
  /// that ceremony as a side effect, or fail halfway into one. Refusing to
  /// act is not refusing to instruct: the exact command is printed, and every
  /// release after the first belongs to rk.
  Future<void> _refuseFirstPublish(
    ResolvedUnit unit,
    Diagnostics problems,
  ) async {
    for (final project in unit.projects) {
      if (!project.channels.contains('pub.dev')) continue;
      final RegistryPackage? package;
      try {
        package = await registry.lookup(project.name);
      } on RegistryUnavailable {
        continue; // the step's own inspection already reports this
      }
      if (package != null) continue;
      problems.add(
        'RK-REG-003',
        '${project.name} has never been published, and a first publish is '
            'not rk\'s to perform',
        remedy: 'the first release accepts the terms and names a publisher, '
            'which is the author\'s ceremony. Run it once by hand:\n'
            '  cd ${project.pubspec.directory} && dart pub publish\n'
            'and every release after it belongs to rk.',
      );
    }
  }

  /// Refuses what this machine cannot finish, before any work rather than at
  /// the last step.
  Diagnostic? _refuseIfUnfinishable(ResolvedUnit unit) {
    if (!unit.shipsBinaries) return null;

    // The same capabilities the chain will build with — a second detect()
    // here let the refusal and the build disagree about what this host is.
    final blocked = <String>[];
    for (final project in unit.projects) {
      for (final platform in project.binaryPlatforms) {
        final resolved = capabilities.resolve(platform);
        if (!resolved.canProduce) {
          blocked.add('$platform — ${resolved.reason}');
        }
      }
    }
    if (blocked.isEmpty) return null;

    return Diagnostic(
      code: 'RK-HOST-001',
      message: 'this machine cannot produce every platform this unit ships',
      remedy: 'starting anyway would build and sign for minutes and then '
          'stop before publishing anything:\n  ${blocked.join('\n  ')}',
    );
  }

  void _validate(ResolvedUnit unit, Diagnostics problems) {
    if (!git.isClean) {
      problems.add(
        'RK-GIT-001',
        '${git.uncommitted.length} paths are uncommitted',
        remedy: 'a release is of a commit, and these are not in one',
      );
    }
    if (!git.headIsPushed) {
      problems.add(
        'RK-GIT-003',
        '${git.shortHead} is not on any remote',
        remedy: 'git push, so the tag points at something others can fetch',
      );
    }
    for (final project in unit.projects) {
      Changelog.check(
        tree: tree,
        manifestDirectory: project.pubspec.directory,
        packageName: project.name,
        version: project.version,
        diagnostics: problems,
      );
    }
  }

  Set<String> _channels(ResolvedUnit unit) {
    final channels = <String>{};
    for (final project in unit.projects) {
      channels.addAll(project.channels);
    }
    return channels;
  }

  /// The operator's presence and typed confirmation are the authorization for
  /// a local release. Where a tag already exists, its signature is.
  Future<bool> _authorize(ResolvedUnit unit, List<Step> remaining) async {
    final permanent = remaining.where((s) => s.isPermanent).toList();

    output.blank();
    if (permanent.isEmpty) {
      output.say('nothing here is permanent.');
    } else {
      output.say('pub.dev never deletes a version. a version can be '
          'retracted, which hides it and removes nothing.');
    }

    if (confirm == null) {
      output.problem(
        Diagnostic(
          code: 'RK-AUTH-001',
          message: 'nobody is here to authorize this release',
          remedy: 'a release from a terminal is authorized by the operator '
              'confirming it. Unattended, rk needs a signed tag instead — '
              'and verifying one is on the ledger, so today unattended '
              'means refused.',
        ),
        unit: unit.name,
      );
      output.halt(HaltKind.beforeActing);
      return false;
    }

    final typed = await confirm!(
      'type ${unit.version} to release, or anything else to stop: ',
    );
    if (typed?.trim() != unit.version.canonical) {
      output.blank();
      output.say(typed == null
          ? 'nobody answered. stopped; nothing was published.'
          : 'stopped. nothing was published.');
      return false;
    }
    return true;
  }

  Future<bool> _act(
    Step step,
    ResolvedUnit unit,
    String? publishedRequirement,
  ) async {
    switch (step.kind) {
      case StepKind.tag:
        return _tag(unit);
      case StepKind.publishRegistry:
        return _publish(step, unit);
      case StepKind.prerequisite:
        return true; // inspected, never performed
      case StepKind.build:
        return _chain(unit).buildStep(
          step,
          _binaryProject(unit),
          publishedRequirement: publishedRequirement,
        );
      case StepKind.sign:
        return _chain(unit).signStep(
          step,
          _binaryProject(unit),
          publishedRequirement: publishedRequirement,
          declaredTeam: resolution.identity?.appleTeam,
          declaredCodeId: resolution.identity?.codeId,
        );
      case StepKind.notarize:
        return _chain(unit).notarizeStep(step, _binaryProject(unit));
      case StepKind.archive:
        return _chain(unit).archiveStep(step, _binaryProject(unit));
      case StepKind.checksums:
        return _chain(unit).checksumsStep(step, _binaryProject(unit));
      case StepKind.publishRelease:
        return _publishRelease(unit, _chain(unit));
      case StepKind.publishFormula:
        return _publishFormula(unit, _chain(unit));
    }
  }

  BinaryChain _chain(ResolvedUnit unit) => BinaryChain(
        tools: tools,
        output: output,
        // Keyed by release and commit, never seeded from another run: a tag
        // deleted and re-pushed at a different commit gets a fresh workspace,
        // so nothing signed from the wrong source can be reused.
        workspace: DirectoryWorkspace(
          '${git.root}/.rk/work/${unit.tag}-${git.shortHead}',
        ),
        repositoryRoot: git.root,
        capabilities: capabilities,
      );

  ResolvedProject _binaryProject(ResolvedUnit unit) =>
      unit.projects.firstWhere((p) => p.config.wantsBinaries);

  /// The designated requirement of the newest already-published release,
  /// which is what this release's signature must reproduce.
  ///
  /// Derived, not declared: the previous version's tag names the release
  /// users already installed, and its binary is the only authority on what
  /// identity this program has. `none` — no earlier signed release — is a
  /// null requirement with `ok`, and the sign step falls back to the
  /// declared `[identity]`. `unreadable` refuses the whole run — before
  /// anything acts, because the version of this that resolved inside the
  /// sign step surfaced an unreadable forge as an internal error after the
  /// tag was already public. Not knowing the baseline is not permission to
  /// ship a new one, and it is also not a bug in rk.
  Future<({bool ok, String? requirement})> _signingBaseline(
    ResolvedUnit unit,
  ) async {
    final repository = git.originUrl;
    if (repository == null) return (ok: true, requirement: null);

    Version? best;
    String? bestTag;
    for (final tag in git.tagsMatching(unit.tagPattern)) {
      final raw = GitState.versionIn(tag, unit.tagPattern);
      final version = raw == null ? null : Version.tryParse(raw);
      if (version == null || version >= unit.version) continue;
      if (best == null || version > best) {
        best = version;
        bestTag = tag;
      }
    }
    if (bestTag == null) return (ok: true, requirement: null); // first release

    final reading = await PublishedIdentity(
      tools: tools,
      repository: repository,
      workingDirectory: git.root,
    ).read(
      tag: bestTag,
      executable: _binaryProject(unit).executable!,
      into: _chain(unit).workspace.pathOf('published-identity'),
    );
    switch (reading.answer) {
      case IdentityAnswer.found:
        return (ok: true, requirement: reading.requirement);
      case IdentityAnswer.none:
        return (ok: true, requirement: null);
      case IdentityAnswer.unreadable:
        output.problem(
          Diagnostic(
            code: 'RK-SIGN-004',
            message: 'the identity users already installed could not be read',
            remedy: '${reading.why}\n'
                'rk proves signing continuity against the release at '
                '$bestTag; until that baseline can be read, a new signature '
                'cannot be proven continuous with it.',
          ),
          unit: unit.name,
        );
        output.halt(HaltKind.beforeActing);
        return (ok: false, requirement: null);
    }
  }

  Future<bool> _publishRelease(ResolvedUnit unit, BinaryChain chain) async {
    final repository = _repository();
    if (repository == null) return false;

    final project = _binaryProject(unit);
    final assets = chain.gatherAssets(project, unit.name);
    if (assets == null) return false;

    // The changelog entry is the release body — one source of release
    // prose, extracted through the same parse that validated its presence,
    // so the notes and the CHANGELOG cannot disagree.
    final notes = _releaseNotes(project);
    if (notes == null) return false;
    chain.workspace.write('release-notes.md', utf8.encode(notes));

    // The formula ships with the release when a tap will point at it, so
    // it is rendered before the create — an immutable release cannot grow
    // it afterwards — and the tap step later pushes these exact bytes.
    final formula = project.channels.contains('homebrew')
        ? chain.renderFormula(
            project: project,
            repository: repository,
            tag: unit.tag,
            assets: assets,
          )
        : null;

    final url = await chain.publishRelease(
      repository: repository,
      tag: unit.tag,
      title: '${project.name} ${unit.version}',
      notesPath: chain.workspace.pathOf('release-notes.md'),
      assets: [...assets, if (formula != null) formula],
    );
    return url != null;
  }

  /// The changelog entry for this version, or null with a recorded problem.
  ///
  /// Validation already proved the heading exists; extraction failing after
  /// that is unexpected, and saying so beats publishing with a body that
  /// silently fell back to something else.
  String? _releaseNotes(ResolvedProject project) {
    final directory = project.pubspec.directory;
    final path = directory == '.' ? 'CHANGELOG.md' : '$directory/CHANGELOG.md';
    final source = tree.read(path);
    final entry =
        source == null ? null : Changelog.entry(source, project.version);
    if (entry == null) {
      output.problem(
        Diagnostic(
          code: 'RK-CHG-003',
          message: 'the changelog entry for ${project.version} could not be '
              'extracted',
          source: SourceLocation(path, 1),
          remedy: 'validation saw a heading for it; the file changed since, '
              'or this is a bug in rk',
        ),
      );
      return null;
    }
    return entry;
  }

  Future<bool> _publishFormula(ResolvedUnit unit, BinaryChain chain) async {
    final repository = _repository();
    if (repository == null) return false;

    final identity = resolution.identity;
    final tap =
        identity?.homebrewTap ?? '${repository.split('/').first}/homebrew-tap';

    return chain.updateFormula(
      tap: tap,
      project: _binaryProject(unit),
    );
  }

  /// The `owner/name` this repository pushes to.
  String? _repository() {
    final remote = git.originUrl;
    if (remote == null) {
      output.line('github-release',
          mark: Mark.blocked, note: 'this repository has no origin remote');
      return null;
    }
    return remote;
  }

  /// Creates and pushes the tag that records this release.
  ///
  /// A record written after the operator authorized, not the authorization
  /// itself — which is why rk may write it here and never may where a tag is
  /// what authorizes.
  Future<bool> _tag(ResolvedUnit unit) async {
    final signed = git.signingConfigured;

    // The step can be half-done: a push that died leaves a local tag, which
    // the inspection now reports as absent-with-work ("not on origin"). The
    // act then pushes what exists rather than failing to re-create it.
    if (git.hasTag(unit.tag)) {
      output.say('the tag exists locally; pushing it', depth: 1);
      return _pushTag(unit, signed: signed, preExisting: true);
    }

    final args = [
      'tag',
      if (signed) '-s' else '-a',
      unit.tag,
      '-m',
      '${unit.name} ${unit.version}',
    ];

    final created = await tools.run('git', args, workingDirectory: git.root);
    if (!created.ok) {
      output.problem(
        Diagnostic(
          code: 'RK-TAG-001',
          message: 'the tag ${unit.tag} could not be created',
          remedy: created.summary,
        ),
        unit: unit.name,
      );
      output.halt(HaltKind.beforeActing);
      return false;
    }

    final pushed = await tools.run(
      'git',
      ['push', 'origin', unit.tag],
      workingDirectory: git.root,
    );
    if (!pushed.ok) {
      // A local tag nobody else can see is a trap, not progress: the next run
      // would report it as work remaining, but a clean refusal beats a
      // half-state. Removing what this run created restores "nothing changed"
      // honestly.
      final removed = await tools.run(
        'git',
        ['tag', '-d', unit.tag],
        workingDirectory: git.root,
      );
      output.problem(
        Diagnostic(
          code: 'RK-TAG-002',
          message: 'the tag ${unit.tag} could not be pushed',
          remedy: removed.ok
              ? '${pushed.summary}\nthe local tag was removed, so re-running '
                  'starts clean'
              : '${pushed.summary}\nand the local tag could not be removed — '
                  'delete it before re-running: git tag -d ${unit.tag}',
        ),
        unit: unit.name,
      );
      output.halt(removed.ok ? HaltKind.beforeActing : HaltKind.lostTrack);
      return false;
    }
    return _verifyTagOnRemote(unit, signed: signed, preExisting: false);
  }

  Future<bool> _pushTag(
    ResolvedUnit unit, {
    required bool signed,
    required bool preExisting,
  }) async {
    final pushed = await tools.run(
      'git',
      ['push', 'origin', unit.tag],
      workingDirectory: git.root,
    );
    if (!pushed.ok) {
      output.problem(
        Diagnostic(
          code: 'RK-TAG-002',
          message: 'the tag ${unit.tag} could not be pushed',
          remedy: '${pushed.summary}\nthe tag pre-existed this run, so it '
              'was left in place — re-running pushes it again',
        ),
        unit: unit.name,
      );
      output.halt(HaltKind.beforeActing);
      return false;
    }
    return _verifyTagOnRemote(unit, signed: signed, preExisting: preExisting);
  }

  /// The tag step's verify leg: done means origin lists it.
  ///
  /// The push's exit code is the push's own word. Trusting it alone let a
  /// killed push produce a release whose authorizing tag existed only on this
  /// machine — and every later inspection, reading local tags, agreed.
  Future<bool> _verifyTagOnRemote(
    ResolvedUnit unit, {
    required bool signed,
    required bool preExisting,
  }) async {
    final remote = await tools.run(
      'git',
      ['ls-remote', 'origin', 'refs/tags/${unit.tag}'],
      workingDirectory: git.root,
    );
    if (!remote.ok || !remote.stdout.contains('refs/tags/${unit.tag}')) {
      output.problem(
        Diagnostic(
          code: 'RK-TAG-003',
          message: 'the push reported success, and origin does not list '
              '${unit.tag}',
          remedy: remote.ok
              ? 're-running pushes it again; if this repeats, look at the '
                  'remote'
              : 'origin could not be read back: ${remote.summary}',
        ),
        unit: unit.name,
      );
      output.halt(HaltKind.lostTrack);
      return false;
    }

    output.line(
      'tag ${unit.tag}',
      mark: Mark.done,
      note: [
        if (signed) 'signed' else 'unsigned',
        'pushed',
        if (preExisting) 'pre-existing local tag',
      ].join(', '),
    );
    return true;
  }

  Future<bool> _publish(Step step, ResolvedUnit unit) async {
    final project = unit.projects.firstWhere((p) => p.name == step.project);
    final directory = project.pubspec.directory == '.'
        ? git.root
        : '${git.root}/${project.pubspec.directory}';

    // Validation and the consumer resolve already ran, pre-act, in the
    // preflight — a refusal there costs nothing public.
    final code = await tools.runInteractive(
      'dart',
      const ['pub', 'publish', '--force'],
      workingDirectory: directory,
    );
    if (code != 0) {
      // Non-zero from an interactive publish is ambiguous: an expired session
      // refused up front, or an upload died after acceptance. rk cannot tell
      // from here, and saying "failed" would claim it can.
      output.problem(
        Diagnostic(
          code: 'RK-PUB-003',
          message: '${project.name}: dart pub publish did not complete',
          remedy: 'if it refused up front (an expired session says run '
              'dart pub login), fix that and re-run; if it died mid-upload, '
              're-running inspects what actually landed',
        ),
        unit: project.unitName,
      );
      output.halt(HaltKind.lostTrack);
      return false;
    }

    // Verify against reality rather than trusting the publisher's own word,
    // polling to a bounded deadline — the registry may take a moment to list
    // what it just accepted — and always on the invalidated cache: rk just
    // acted on this coordinate, so what it knew is stale by its own hand.
    var waited = Duration.zero;
    Inspection after;
    while (true) {
      registry.forget(project.name);
      after = await registry.inspect(project.name, project.version);
      if (after.isExact) break;
      if (waited >= confirmDeadline) {
        output.line(
          project.name,
          mark: Mark.blocked,
          note: 'published, but pub.dev does not report it after '
              '${waited.inSeconds}s',
        );
        output.halt(HaltKind.lostTrack);
        output.say('re-run to confirm; nothing else is needed', depth: 1);
        return false;
      }
      await _wait(confirmInterval);
      waited += confirmInterval;
    }

    // The version existing is not the right bytes existing: download what
    // the registry now serves and prove it against this tree, through the
    // same comparator verify wears.
    return _confirmPublishedBytes(project);
  }

  /// pub's validation and the consumer resolve, both read-only.
  ///
  /// The gate matches what the act will do. `dart pub publish --dry-run`
  /// exits non-zero for warnings and for errors alike, while `--force` — the
  /// actual act — publishes past warnings and refuses errors. Gating on the
  /// exit code alone made rk stricter than the registry it publishes to:
  /// keybay's deliberate, test-enforced exact pins are "warnings", pub.dev
  /// accepted them at 0.1.0, and rk would have refused the release — after
  /// pushing the tag. Warnings are printed, so the operator confirms the
  /// permanent act having seen them; errors block; a summary rk cannot
  /// classify blocks, because fail-closed is for the unrecognised.
  Future<bool> _publishPreflight(ResolvedProject project) async {
    final directory = project.pubspec.directory == '.'
        ? git.root
        : '${git.root}/${project.pubspec.directory}';

    final dry = await tools.run(
      'dart',
      const ['pub', 'publish', '--dry-run'],
      workingDirectory: directory,
    );
    final validation = '${dry.stdout}\n${dry.stderr}'.trim();
    output.report.attach('pub-dry-run-${project.name}.txt', validation);

    if (!dry.ok) {
      final summary = RegExp(r'Package has[^\n]*')
          .allMatches(validation)
          .map((m) => m.group(0)!)
          .lastOrNull;
      final warningsOnly = summary != null &&
          !summary.toLowerCase().contains('error') &&
          summary.toLowerCase().contains('warning');
      if (!warningsOnly) {
        output.problem(
          Diagnostic(
            code: 'RK-PUB-001',
            message: 'pub refuses to publish ${project.name}',
            remedy: validation.isEmpty ? dry.summary : validation,
          ),
          unit: project.unitName,
        );
        output.halt(HaltKind.beforeActing);
        return false;
      }
      // The same warnings pub's interactive publish would have shown, shown —
      // the operator confirms the permanent act having seen them.
      output.say('pub warns, and --force will publish past these:', depth: 1);
      for (final line in validation.split('\n')) {
        if (line.trimLeft().startsWith('*')) output.say(line.trim(), depth: 2);
      }
    }

    return _consumerResolve(project, directory);
  }

  /// Resolution as every consumer will see it. False halts the step.
  Future<bool> _consumerResolve(
    ResolvedProject project,
    String directory,
  ) async {
    final probe = Directory.systemTemp.createTempSync('rk-consumer-');
    try {
      File('${probe.path}/pubspec.yaml').writeAsStringSync('''
name: rk_consumer_probe
publish_to: none
environment:
  sdk: '>=3.0.0 <4.0.0'
dependencies:
  ${project.name}: ${project.version}
dependency_overrides:
  ${project.name}:
    path: ${directory.replaceAll('\\', '/')}
''');
      final resolved = await tools.run(
        'dart',
        const ['pub', 'get', '--no-precompile'],
        workingDirectory: probe.path,
      );
      if (!resolved.ok) {
        output.problem(
          Diagnostic(
            code: 'RK-PUB-002',
            message: '${project.name}: consumers could not resolve this',
            remedy: '${resolved.summary}\n'
                'the probe resolves as a Dart consumer on this SDK; a '
                'package needing Flutter or a newer SDK than the probe '
                'models is a limit rk has not lifted yet — see the ledger',
          ),
          unit: project.unitName,
        );
        output.halt(HaltKind.beforeActing);
        return false;
      }
      return true;
    } finally {
      probe.deleteSync(recursive: true);
    }
  }

  /// Downloads what the registry serves for the version just published and
  /// proves it byte-for-byte against this tree.
  Future<bool> _confirmPublishedBytes(ResolvedProject project) async {
    RegistryPackage? package;
    try {
      package = await registry.lookup(project.name);
    } on RegistryUnavailable {
      package = null;
    }
    final published = package?.at(project.version);

    final List<int> archive;
    try {
      if (published == null) {
        throw RegistryUnavailable('the version vanished between reads');
      }
      archive = await registry.archive(published);
    } on ArchiveTampered catch (tampered) {
      output.problem(
        Diagnostic(
          code: 'RK-VER-004',
          message: '${project.name} ${project.version}: $tampered',
          remedy: 'the registry is serving bytes that do not match its own '
              'digest for what rk just published — stop and look',
        ),
        unit: project.unitName,
      );
      output.halt(HaltKind.actedAndUnfixable);
      output.report.rerunHelps = false;
      return false;
    } on RegistryUnavailable catch (error) {
      output.problem(
        Diagnostic(
          code: 'RK-PUB-004',
          message: '${project.name} ${project.version}: published, and the '
              'archive could not be read back',
          remedy: '${error.message}\nthe byte proof is one command away: '
              'rk verify',
        ),
        unit: project.unitName,
      );
      output.halt(HaltKind.lostTrack);
      output.next('rk verify ${project.unitName}');
      return false;
    }

    final comparison = await comparator.compare(
      archive: archive,
      tree: tree,
      packageDirectory: project.pubspec.directory,
    );

    switch (comparison.verdict) {
      case Verdict.exact:
        output.line(
          '${project.name} ${project.version}',
          mark: Mark.done,
          note: 'published · ${comparison.detail}',
        );
        return true;
      case Verdict.unknown:
        output.line(
          '${project.name} ${project.version}',
          mark: Mark.blocked,
          note: 'published, and not fully provable: ${comparison.detail}',
        );
        output.halt(HaltKind.lostTrack);
        return false;
      case Verdict.conflict || Verdict.absent:
        // The one unforgivable outcome: the registry serves bytes this tree
        // cannot account for, one step after rk published. Permanent, and
        // said as data — an agent must not retry a release that can never
        // succeed.
        output.problem(
          Diagnostic(
            code: 'RK-VER-006',
            message: '${project.name} ${project.version}: '
                '${comparison.detail ?? 'differs from this source'}',
            remedy: 'what is published is public and cannot be edited. If '
                'this difference is not yours, treat it as an incident; if '
                'it is, the only way forward is the next version.',
          ),
          unit: project.unitName,
        );
        for (final entry in comparison.evidence.entries) {
          output.say('${entry.key}  ${entry.value}', depth: 1);
        }
        output.halt(HaltKind.actedAndUnfixable);
        output.report.rerunHelps = false;
        return false;
    }
  }
}

/// Reads a confirmation from the terminal, or nothing when there is no
/// terminal to read from.
Future<String?> promptOnTerminal(String prompt) async {
  if (!stdin.hasTerminal) return null;
  stdout.write(prompt);
  return stdin.readLineSync();
}
