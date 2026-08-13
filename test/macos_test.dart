import 'package:rk/src/engine/tools.dart';
import 'package:rk/src/transforms/macos.dart';
import 'package:test/test.dart';

const _name = 'Developer ID Application: Dan (TEAM123456)';
final _sha1 = 'a' * 40;
final _otherSha1 = 'b' * 40;
final _sha256 = 'c' * 64;
final _otherSha256 = 'd' * 64;

void main() {
  test('correlates the selected identity to its SHA-256 certificate block',
      () async {
    final tools = _tools(certificateOutput: '''
SHA-256 hash: $_otherSha256
SHA-1 hash: $_otherSha1
keychain: "/tmp/other.keychain"
SHA-256 hash: $_sha256
SHA-1 hash: $_sha1
keychain: "/tmp/login.keychain-db"
''');
    final signer = MacOsSigner(tools: tools);

    final identities = await signer.availableIdentities();

    expect(identities, hasLength(1));
    expect(identities!.single.sha1, _sha1);
    expect(await signer.certificateSha256(identities.single), _sha256);
    expect(
      tools.calls,
      contains('security find-certificate -a -c $_name -Z'),
    );
  });

  test('signing carries the exact certificate SHA-256 fingerprint', () async {
    final tools = _tools(certificateOutput: '''
SHA-256 hash: $_sha256
SHA-1 hash: $_sha1
''');
    final signer = MacOsSigner(tools: tools);
    final identity = (await signer.availableIdentities())!.single;

    final signed = await signer.sign(
      binary: '/tmp/tool',
      team: 'TEAM123456',
      codeId: 'io.example.tool',
      selectedIdentity: identity,
      expectedCertificateSha256: _sha256,
    );

    expect(signed.ok, isTrue);
    expect(signed.certificate, _name);
    expect(signed.certificateSha256, _sha256);
    expect(
      tools.calls.where((call) => call.startsWith('codesign --force')).single,
      contains('--sign $_sha1 /tmp/tool'),
    );
    expect(tools.calls, contains('codesign --verify --strict /tmp/tool'));
    expect(
      tools.calls.indexOf('codesign --verify --strict /tmp/tool'),
      greaterThan(tools.calls.indexOf('codesign -d -r- /tmp/tool')),
      reason: 'the readable requirement is not proof that the signed bytes '
          'verify; both checks must finish before the outcome is recordable',
    );
  });

  test('a newly written signature must verify before it is recordable',
      () async {
    final tools = _tools(
      certificateOutput: '''
SHA-256 hash: $_sha256
SHA-1 hash: $_sha1
''',
      signatureVerifies: false,
    );
    final signer = MacOsSigner(tools: tools);

    final signed = await signer.sign(
      binary: '/tmp/tool',
      team: 'TEAM123456',
      codeId: 'io.example.tool',
    );

    expect(signed.ok, isFalse);
    expect(signed.requirement, isNull);
    expect(signed.problem, contains('did not verify after signing'));
    expect(tools.calls, contains('codesign -d -r- /tmp/tool'));
    expect(tools.calls, contains('codesign --verify --strict /tmp/tool'));
  });

  test('an unreadable fingerprint fails before codesign can mutate bytes',
      () async {
    final tools = _tools(certificateOutput: '');
    final signer = MacOsSigner(tools: tools);

    final signed = await signer.sign(
      binary: '/tmp/tool',
      team: 'TEAM123456',
      codeId: 'io.example.tool',
    );

    expect(signed.ok, isFalse);
    expect(signed.problem, contains('fingerprint could not be read'));
    expect(tools.calls.where((call) => call.startsWith('codesign --force')),
        isEmpty);
  });
}

RecordingTools _tools({
  required String certificateOutput,
  bool signatureVerifies = true,
}) =>
    RecordingTools(
      answers: (key) {
        if (key == 'security find-identity -v -p codesigning') {
          return ToolResult(
            exitCode: 0,
            stdout: '1) $_sha1 "$_name"',
            stderr: '',
          );
        }
        if (key.startsWith('security find-certificate')) {
          return ToolResult(
            exitCode: 0,
            stdout: certificateOutput,
            stderr: '',
          );
        }
        if (key.startsWith('codesign -d -r-')) {
          return ToolResult(
            exitCode: 0,
            stdout: 'designated => identifier "io.example.tool"',
            stderr: '',
          );
        }
        if (key.startsWith('codesign --verify --strict')) {
          return ToolResult(
            exitCode: signatureVerifies ? 0 : 1,
            stdout: '',
            stderr: signatureVerifies ? '' : 'invalid signature',
          );
        }
        return null;
      },
    );
