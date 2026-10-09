import 'dart:io';

import 'package:rk/src/engine/stage.dart';

void main(List<String> args) {
  final stages = Stages(args.first);
  if (args.length == 2 && args.last == 'try') {
    try {
      stages.lock().close();
      stdout.writeln('acquired');
    } on StageStoreBusy {
      stdout.writeln('busy');
    }
    return;
  }
  final lock = stages.lock();
  stdout.writeln('locked');
  stdin.readLineSync();
  lock.close();
}
