#!/bin/bash
set -euo pipefail

# Read-only monitor for Apple's Bluetooth A2DP/AAC adaptation logs.
# No defaults writes, daemon restarts, device disconnects, or preference changes.
# Usage: ./bt-aac-log-monitor.sh [seconds]
seconds="${1:-60}"
[[ "$seconds" =~ ^[0-9]+$ ]] || { echo "seconds must be an integer" >&2; exit 2; }

predicate='(process == "coreaudiod" OR process == "bluetoothaudiod") AND (eventMessage CONTAINS[c] "SetLinkAdaptiveEncoderRateFromBT" OR eventMessage CONTAINS[c] "Target Bitrate" OR eventMessage CONTAINS[c] "Actual target Bitrate" OR eventMessage CONTAINS[c] "Creating AAC-LC Encoder" OR eventMessage CONTAINS[c] "A2DP")'

echo "Monitoring Bluetooth AAC/A2DP adaptation for ${seconds}s..." >&2
# macOS `log stream` has no portable duration flag; timeout via a background killer.
log stream --style compact --level debug --predicate "$predicate" &
pid=$!
trap 'kill "$pid" 2>/dev/null || true' EXIT INT TERM
sleep "$seconds"
kill "$pid" 2>/dev/null || true
wait "$pid" 2>/dev/null || true
