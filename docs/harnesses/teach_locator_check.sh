#!/usr/bin/env bash
# Runs docs/harnesses/teach_locator_check.swift against the REAL
# `TeachSentenceLocator` — the pure half of teach-by-voice (the sentence test's
# locator + the alias merge that writes vocabulary to disk).
#
# Same shape as splice_check.sh: no mirror of the algorithm lives here. The app
# source and jot-shared's `CorrectionKey` are concatenated ahead of the cases
# and compiled as one script, so this stays a standalone `swift` run (no
# package, no Xcode) while testing the code that actually ships. The `JotTests`
# target still can't build (pre-existing FluidAudio reason), so this is the only
# executable coverage this logic has.
#
# The one transformation: the locator's `import JotVocabCore` is stripped,
# because `CorrectionKey`'s source is concatenated in rather than imported as a
# module. Nothing else is touched — if the file grows a second package
# dependency this script must be updated, and it will fail loudly rather than
# silently testing a stale copy.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
key="${JOT_SHARED:-$repo/../jot-shared}/Sources/JotVocabCore/CorrectionKey.swift"
locator="$repo/Jot/App/Vocabulary/TeachSentenceLocator.swift"
for f in "$key" "$locator"; do
  if [ ! -f "$f" ]; then
    echo "missing source: $f (set JOT_SHARED if jot-shared lives elsewhere)" >&2
    exit 1
  fi
done
cat "$key" <(sed '/^import JotVocabCore$/d' "$locator") "$here/teach_locator_check.swift" | swift -
