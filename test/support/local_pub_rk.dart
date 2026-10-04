// Uses the shared CLI composition with an explicit local service endpoint.
// The shipped entry point never reads this endpoint from the environment.
import 'dart:io';

import 'package:rk/src/targets/pub_dev/endpoint.dart';

import '../../bin/rk.dart' as rk;

Future<void> main(List<String> args) => rk.runRk(
  args,
  pubEndpoint: PubEndpoint.loopback(
    Uri.parse(Platform.environment['PUB_HOSTED_URL']!),
  ),
);
