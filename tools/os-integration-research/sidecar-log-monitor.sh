#!/bin/bash
set -euo pipefail
PRED='(process == "SidecarDisplayAgent" OR process == "SidecarRelay" OR process == "ControlCenter")'
FILTER='codec|HEVC|H\.264|framerate|frame rate|bitrate|txMax|txMin|config:|Sidecar|display|transport|lowLatency'
if [ "${1:-}" = "--last" ]; then
  LAST="${2:-10m}"
  /usr/bin/log show --style compact --info --debug --last "$LAST" --predicate "$PRED" 2>/dev/null | grep -Ei "$FILTER" || true
else
  echo 'Streaming Sidecar logs. Ctrl-C to stop.'
  /usr/bin/log stream --style compact --info --debug --predicate "$PRED" 2>/dev/null | grep --line-buffered -Ei "$FILTER"
fi
