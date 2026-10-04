import 'package:rk_qualification_core/rk_qualification_core.dart';

void checkMessage(String actual) {
  final expected = 'value=$coreValue; core=$coreValue';
  if (actual != expected) throw StateError('Expected $expected, got $actual');
}
