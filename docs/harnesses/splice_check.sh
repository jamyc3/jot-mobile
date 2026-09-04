#!/usr/bin/env bash
# Runs docs/harnesses/splice_check.swift against the SHARED PasteEditResolver.
#
# The harness has no mirror of the algorithm any more — it compiles jot-shared's
# `PasteEditResolver.swift` together with the cases as one script, so it stays a
# standalone `swift` run (no package, no Xcode) while testing the real code.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
resolver="${JOT_SHARED:-$repo/../jot-shared}/Sources/JotVocabCore/PasteEditResolver.swift"
if [ ! -f "$resolver" ]; then
  echo "PasteEditResolver.swift not found at $resolver (set JOT_SHARED)" >&2
  exit 1
fi
cat "$resolver" "$here/splice_check.swift" | swift -
