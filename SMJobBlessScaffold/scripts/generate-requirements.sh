#!/bin/bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <signed-host-app-binary> <signed-helper-binary>"
  echo "Example:"
  echo "  $0 /path/PortManager.app/Contents/MacOS/PortManager /path/com.erlinhoxha.portmanager.helper"
  exit 1
fi

HOST_BIN="$1"
HELPER_BIN="$2"

if [ ! -f "$HOST_BIN" ]; then
  echo "Host binary not found: $HOST_BIN" >&2
  exit 2
fi
if [ ! -f "$HELPER_BIN" ]; then
  echo "Helper binary not found: $HELPER_BIN" >&2
  exit 3
fi

echo "Host requirement:"
codesign -d -r- "$HOST_BIN" 2>&1 | sed -n 's/^designated => //p'
echo
echo "Helper requirement:"
codesign -d -r- "$HELPER_BIN" 2>&1 | sed -n 's/^designated => //p'
