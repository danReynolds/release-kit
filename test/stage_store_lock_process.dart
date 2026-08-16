import 'dart:io';

import 'package:rk/src/engine/stage_store.dart';

void main(List<String> args) {
  final store = StageStore(args.first);
  if (args.length == 2 && args.last == 'try') {
    try {
      store.acquireForMutation().close();
      stdout.writeln('acquired');
    } on StageStoreBusy {
      stdout.writeln('busy');
    }
    return;
  }
  final lock = store.acquireForMutation();
  stdout.writeln('locked');
  stdin.readLineSync();
  lock.close();
}
