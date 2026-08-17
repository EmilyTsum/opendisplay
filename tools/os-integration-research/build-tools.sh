#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
OUT="${1:-build}"
mkdir -p "$OUT"
clang -fobjc-arc -framework Foundation -framework CoreFoundation sidecar-intent-probe.m -o "$OUT/sidecar-intent-probe"
clang -fobjc-arc -framework Foundation sidecar-config-dump.m -o "$OUT/sidecar-config-dump"
clang -fobjc-arc -framework Foundation sidecar-native-tune.m -o "$OUT/sidecar-native-tune"
printf 'Built:\n'
ls -l "$OUT/sidecar-intent-probe" "$OUT/sidecar-config-dump" "$OUT/sidecar-native-tune"
