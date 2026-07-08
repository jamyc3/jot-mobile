import Foundation
import SwiftData

/// Migration plan for the Jot SwiftData store. Flyway-style: every shipped
/// schema version is frozen, evolution happens by appending new versions
/// and `MigrationStage`s.
///
/// **DO NOT open `JotModelContainer.shared` from the keyboard target.**
/// The keyboard process reads `TranscriptHistoryMirror` JSON only — see
/// `Jot/AGENTS.md`. Opening the SwiftData container from the extension
/// breaks the cross-process invariant and risks store corruption.
///
/// **To add a new schema version (V → V+1):**
///
/// 1. Create `JotSchemaV(N+1).swift` with the new `@Model` shape. Start
///    by copying `JotSchemaVN.swift`, then add new fields / new entity
///    types. Never remove or rename existing fields without a `.custom`
///    migration stage.
/// 2. **Bump `versionIdentifier`** in the new file to a new value (e.g.
///    `Schema.Version(2, 0, 0)`). Without a unique identifier, SwiftData
///    cannot distinguish V1 from V2 and the migration plan corrupts
///    the store.
/// 3. Append `JotSchemaV(N+1).self` to `schemas` below (chronological
///    order; latest last).
/// 4. Add a `MigrationStage` to `stages` describing the V → V+1 traversal:
///    - Additive optional fields → `.lightweight(...)`.
///    - New entity types alongside existing ones → `.lightweight(...)`
///      (SwiftData handles new entities automatically).
///    - Field rename / split / default-fill / type change → `.custom(...)`
///      with `willMigrate` and/or `didMigrate` closures.
/// 5. Update the `Transcript` typealias (and any other model typealiases)
///    in `Jot/Shared/Transcript.swift` to point at the new VN type.
/// 6. Update `JotModelContainer.shared` in `TranscriptStore.swift` to use
///    `Schema(versionedSchema: JotSchemaV(N+1).self)`.
/// 7. **Run `xcodegen` from `Jot/`** to refresh the Xcode project so the
///    new schema file is compiled into both targets.
/// 8. Update `docs/schema-migrations.md` "Current versions" list with
///    the new VN entry (date, build, summary of fields added).
/// 9. **NEVER** modify a prior `JotSchemaV<earlier>.swift` file. Frozen
///    for life. `scripts/check-schema-frozen.sh` blocks PRs that do.
/// 10. **Test the upgrade path on a real device.** Install the prior
///     build, dictate transcripts, install the new build, confirm
///     transcripts load. In Console.app filter for `[SCHEMA-FALLBACK]`
///     — if that log fires, the VersionedSchema path is failing and
///     the migration needs investigation before merge.
enum JotMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [JotSchemaV1.self, JotSchemaV2.self, JotSchemaV3.self, JotSchemaV4.self, JotSchemaV5.self, JotSchemaV6.self, JotSchemaV7.self, JotSchemaV8.self, JotSchemaV9.self]
        // Future: append V10.self, ... in chronological order.
    }

    static var stages: [MigrationStage] {
        [
            // V1 → V2: additive optional `rewriteUserEdit: String?` on
            // `Transcript`. `nil` for every pre-existing V1 row on first
            // V2 read. Lightweight inference handles this case reliably.
            .lightweight(
                fromVersion: JotSchemaV1.self,
                toVersion: JotSchemaV2.self
            ),
            // V2 → V3: additive optional `rewriteUpvoted: Bool?` on
            // `Transcript`. `nil` for every pre-existing V2 row on first
            // V3 read. Lightweight inference, same shape as V1→V2.
            .lightweight(
                fromVersion: JotSchemaV2.self,
                toVersion: JotSchemaV3.self
            ),
            // V3 → V4: additive optional `category: String?` on
            // `Transcript`. `nil` for every pre-existing V3 row on first
            // V4 read; classifier picks up the backlog on first BG fire.
            .lightweight(
                fromVersion: JotSchemaV3.self,
                toVersion: JotSchemaV4.self
            ),
            // V4 → V5: TWO additive optional fields on `Transcript` —
            // `source: String?` (capture surface tag: watch/app/keyboard/
            // shortcut/file) and `watchOriginUUID: String?` (de-dup key
            // for watch retransmits). Both `nil` for every pre-existing
            // V4 row on first V5 read. UI treats nil source as "app".
            .lightweight(
                fromVersion: JotSchemaV4.self,
                toVersion: JotSchemaV5.self
            ),
            // V5 → V6: TWO new `@Model` entities alongside `Transcript` —
            // `TranscriptEmbedding` (MiniLM-L6-v2 384-d vectors) and
            // `TranscriptCategory` (substrate for a future classifier,
            // no writers in this PR). `Transcript`'s shape is unchanged
            // (the legacy `category` field is preserved as dead-data —
            // see the banner in `JotSchemaV6.Transcript.category`).
            // SwiftData handles both new entities in one inference pass.
            .lightweight(
                fromVersion: JotSchemaV5.self,
                toVersion: JotSchemaV6.self
            ),
            // V6 → V7: ONE new `@Model` entity alongside the existing ones —
            // `TranscriptChunk` (chunk-level embeddings + denormalized filter
            // metadata for the Ask RAG pipeline). Purely additive: `Transcript`
            // is untouched and `TranscriptEmbedding` is retained (deprecated).
            // SwiftData handles the new entity in one inference pass — same
            // shape as the V5→V6 add. The deprecated `TranscriptEmbedding` table
            // is dropped in a later `.custom` V7→V8 stage once the chunk
            // pipeline is cut over (one device-testable migration at a time).
            .lightweight(
                fromVersion: JotSchemaV6.self,
                toVersion: JotSchemaV7.self
            ),
            // V7 → V8: ONE additive optional field on `Transcript` —
            // `language: String?` (the raw `LanguageChoice` the recording was
            // dictated in — sibling to `source`). `nil` for every pre-existing
            // V7 row on first V8 read; UI / Translate treat nil as English.
            // Lightweight inference, same shape as the V4→V5 `source` add.
            .lightweight(
                fromVersion: JotSchemaV7.self,
                toVersion: JotSchemaV8.self
            ),
            // V8 → V9: ONE additive optional field on `Transcript` —
            // `diarizationJSON: String?` (a JSON-encoded `[PersistedSpeakerRow]`
            // holding the resolved speaker turns, or `nil` when the transcript
            // was never diarized / was single-speaker). `nil` for every
            // pre-existing V8 row on first V9 read. Lightweight inference, same
            // shape as the V7→V8 `language` add. Drives the Speaker Notes
            // detail tab (`docs/plans/speaker-notes-productization.md`).
            .lightweight(
                fromVersion: JotSchemaV8.self,
                toVersion: JotSchemaV9.self
            )
        ]
    }
}
