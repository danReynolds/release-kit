#!/bin/sh
# Run inside the extracted source archive; no pub get or network is needed.
set -eu
if [ "$#" != 1 ]; then
  echo 'Usage: rebuild.sh <Dart 3.13.5 SDK directory>' >&2
  exit 64
fi
sdk=$(CDPATH= cd -- "$1" && pwd -P)
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64|Linux-aarch64|Linux-arm64|Linux-x86_64) ;;
  *) echo 'Rebuild on macOS arm64 or Linux arm64/x64.' >&2; exit 64 ;;
esac
if [ "$(cat "$sdk/version")" != 3.13.5 ] ||
   [ "$(cat "$sdk/revision")" != 04bcd1036cdc799ac6564988f159ee454d42c822 ]; then
  echo 'This preview requires Dart SDK 3.13.5 (04bcd1036cdc).' >&2
  exit 64
fi
cd -- "$(dirname -- "$0")"
"$sdk/bin/dart" --suppress-analytics compile aot-snapshot \
  --packages=package_config.json main.dart -o build.aot
./rk-dart-build "$sdk" --help
