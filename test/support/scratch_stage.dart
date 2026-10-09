import 'package:rk/src/engine/stage.dart';

import 'memory_source_tree.dart';

/// An empty stage under [root], for producers that only read and write
/// files in it.
Stage scratchStage(String root) => Stage(
  root: root,
  id: StageId.of(commit: '1' * 40, tree: '2' * 40, plan: const {}),
  plan: const {},
  source: MemorySourceTree({}),
);
