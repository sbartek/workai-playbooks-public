#!/usr/bin/env bash
# Tests for tools/youtrack-sync (fake YouTrack, no network, no secret store).
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
out="$(python3 -m unittest -q "$here/tools/youtrack-sync/test_youtrack_sync.py" 2>&1)"; rc=$?
printf '%s\n' "$out" | tail -5
[ "$rc" = 0 ] && echo "all tests pass" || { echo "youtrack-sync tests failed"; exit 1; }
