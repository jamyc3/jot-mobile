# Bug: dictation inside transcript Edit mode sometimes not saved (silently thrown away)

**Status:** Symptom recorded 2026-07-05, NOT fixed. **Size: diagnosis-first, S.**

## Symptom
Open a transcript's detail pane, tap **Edit**, start voice dictation (via the Jot
keyboard's mic control, which is what's raised over the edit field), stop. Sometimes
the dictated text lands in the field as expected; other times it's silently thrown
away — the field doesn't reflect what was just dictated, and nothing is saved.
Intermittent, not every time.

## Context / why this is a distinct bug from the existing duplicate-paste doc
`docs/plans/bug-in-app-dictation-duplicate-paste.md` documents a *different* Edit-mode
dictation symptom (text landing **twice**) whose root cause was a race between the
keyboard's cross-process auto-paste flush and an in-process `FocusedFieldInsert`
bridge. That bridge **no longer exists** — it was deleted in the root-view-decouple
refactor (commit `c79ebac`, per `Jot/ARCHITECTURE.md:125` and `Jot/CLAUDE.md`'s
"DICTATION ARCHITECTURE — unification COMPLETE" section). Since that refactor, an
in-Jot stop (Edit field included) is delivered through the **exact same single
keyboard auto-paste path** (`flushPendingAutoPasteIfPossible`,
`Jot/Keyboard/JotKeyboardViewController.swift`) used for every other host app — there
is no separate "in-app" code path anymore, and no dual-deliverer race is possible.
That old doc is stale as of this refactor and should be marked superseded separately
from this new report.

**Persistence is a second, separate step.** Dictation only mutates the local
`editorText` state (via `InlineEditTextView`'s `UITextViewDelegate`,
`Jot/App/InlineEditTextView.swift:104-116`). Nothing is written to the actual
`Transcript` until the user taps **Save**, which calls
`TranscriptStore.update(id:text:rewriteUserEdit:)`
(`TranscriptDetailView.swift:1903-1977`, write at `:1957`). **Cancel discards
`editorText` unconditionally**, including any text a dictation just inserted, with no
confirmation prompt — the view already guards against *navigation*-triggered loss
(back-chevron disabled while editing, interactive-pop-gesture disabled, a manual
edge-swipe guard — all commented as protecting "unsaved edits") but has no equivalent
guard against tapping Cancel right after a successful dictation.

## Candidate mechanisms (not yet disambiguated — need a failing on-device log)

1. **Silent flush-clear on a stale/expired payload.** If a flush attempt finds
   `ClipboardHandoff.readFresh()` returning `nil` (payload already consumed, or past
   its ~30s freshness window) while the session already appears in the terminal log,
   the keyboard clears the pending session with **no insert and no visible signal**:
   `JotKeyboardViewController.swift:1996-2001` ("Pending session … appears in terminal
   log; clearing."). This is a genuine silent-drop path if a later flush (e.g. on
   `viewWillAppear`) hits this branch instead of the original settled-`.idle` flush.
2. **Revert-after-landing → redirected to a keyboard banner, not the field.** A
   deferred ~350ms settle-check can decide the initial insert didn't really land and
   fall back to a "tap to paste" clipboard banner instead of retrying
   (`fallbackToClipboardWithBanner`, `JotKeyboardViewController.swift:1809-1899`).
   From the Edit field's perspective this looks exactly like "the text vanished" —
   it's recoverable via the banner, but a user focused on the field (not the
   keyboard's banner) may not notice it fired at all.
3. **Same root family as the already-recorded (deferred) empty-field bug** —
   [bug-rare-empty-field-first-paste-miss.md](bug-rare-empty-field-first-paste-miss.md):
   `documentContextBeforeInput` returns `nil` for both a disconnected proxy and a
   genuinely empty-but-live field, so the after-insert `landed` check can
   misclassify a real insert as failed on an empty Edit field (or right at an
   edge where the pre-caret context is empty) and keep it pending instead of
   confirming it. Same code, not yet verified against this specific view.
4. **Full Access gate.** If Full Access is off (or transiently revoked), the flush
   no-ops entirely (`JotKeyboardViewController.swift:1494-1504`) — logged internally
   (`pasteSkipNoFullAccess`) but invisible to the user. Worth ruling out first since
   it's the cheapest check.
5. **Non-bug candidate: user tapped Cancel, not Save.** Since Cancel discards
   `editorText` unconditionally with no warning, some reports of "it got thrown away"
   may simply be a successful dictation followed by tapping Cancel instead of Save.
   Worth asking the user which button they tapped before assuming an engine bug.

## Where to look when picked up
- `JotKeyboardViewController.flushPendingAutoPasteIfPossible` and its `landed`
  computation / diagnostics (`pasteSuccess`, `pasteSkipProxyDisconnected`,
  `pasteSkipNoFullAccess`, the "appears in terminal log; clearing" line).
- `TranscriptDetailView.saveEdit()` / `cancelEdit()` (`TranscriptDetailView.swift`)
  for the separate persistence step.
- Related: [bug-in-app-dictation-duplicate-paste.md](bug-in-app-dictation-duplicate-paste.md)
  (stale/superseded — same subsystem, opposite symptom, pre-refactor architecture),
  [bug-rare-empty-field-first-paste-miss.md](bug-rare-empty-field-first-paste-miss.md)
  (same candidate mechanism, different host).

## Next step (needs device)
Diagnostic-first — do not ship a fix before a captured failing log. Reproduce once,
then pull Help → Diagnostics and check, in order: (1) was Full Access on, (2) which
of `pasteSuccess` / `pasteSkipProxyDisconnected` / "appears in terminal log; clearing"
fired for that session, (3) did a clipboard banner appear that the user didn't
notice, (4) did the user tap Save or Cancel after dictating. That combination
narrows the 5 candidates above to one before any fix is attempted.
