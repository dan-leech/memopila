import Foundation
import Testing
@testable import MemopilaServices

@Suite("Store migration recovery")
struct MigrationRecoveryTests {
    /// Pre-`useCount` V3 store (no `ZUSECOUNT`); staged plan fails, inferred open upgrades.
    @Test func should_open_pre_useCount_store_via_inferred_fallback() async throws {
        let fixture = try #require(Bundle.module.url(forResource: "PreUseCountV3", withExtension: "store"))
        let tmp = FileManager.default.temporaryDirectory.appending(path: "memopila-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dest = tmp.appending(path: "History.store")
        try FileManager.default.copyItem(at: fixture, to: dest)

        let store = try ClipboardStore(url: dest)
        #expect(try await store.count(HistoryQuery()) == 2)
        let cards = try await store.page(HistoryQuery(), offset: 0, limit: 10)
        #expect(cards.count == 2)
        #expect(cards.allSatisfy { $0.useCount == 0 })

        // Second open uses the staged plan on the upgraded file.
        let again = try ClipboardStore(url: dest)
        #expect(try await again.count(HistoryQuery()) == 2)
    }
}
