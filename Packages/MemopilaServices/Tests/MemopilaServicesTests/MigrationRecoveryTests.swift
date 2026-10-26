import Foundation
import Testing
@testable import MemopilaServices

@Suite("Store migration recovery")
struct MigrationRecoveryTests {
    /// Dev-machine fixture: Application Support Unreadable backup from pre-useCount V3.
    /// Skips cleanly when the file is absent (CI).
    @Test func should_open_pre_useCount_store_via_inferred_fallback() async throws {
        let backup = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/Memopila/Unreadable History 2026-10-26 21.47.49/History.store")
        guard FileManager.default.fileExists(atPath: backup.path) else { return }
        let tmp = FileManager.default.temporaryDirectory.appending(path: "memopila-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.copyItem(at: backup, to: tmp.appending(path: "History.store"))
        let support = backup.deletingLastPathComponent().appending(path: ".History_SUPPORT")
        if FileManager.default.fileExists(atPath: support.path) {
            try FileManager.default.copyItem(at: support, to: tmp.appending(path: ".History_SUPPORT"))
        }
        let store = try ClipboardStore(url: tmp.appending(path: "History.store"))
        #expect(try await store.count(HistoryQuery()) == 359)
        let again = try ClipboardStore(url: tmp.appending(path: "History.store"))
        #expect(try await again.count(HistoryQuery()) == 359)
    }
}
