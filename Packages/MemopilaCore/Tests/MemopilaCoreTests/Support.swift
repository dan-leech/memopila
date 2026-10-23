import Foundation
@testable import MemopilaCore

/// In-memory pasteboard for reader tests. `nil` data on a declared type simulates a failed read.
final class FakePasteboard: PasteboardSource {
    var changeCount: Int
    var items: [[(type: PasteboardType, data: Data?)]]
    private(set) var reads: [PasteboardType] = []
    /// Called on every data read; lets a test change the pasteboard mid-read.
    var onRead: ((FakePasteboard, PasteboardType) -> Void)?

    init(changeCount: Int = 1, items: [[(type: PasteboardType, data: Data?)]]) {
        self.changeCount = changeCount
        self.items = items
    }

    func itemTypes() -> [[PasteboardType]] {
        items.map { $0.map(\.type) }
    }

    func data(forItem index: Int, type: PasteboardType) -> Data? {
        reads.append(type)
        onRead?(self, type)
        return items[index].first { $0.type == type }?.data ?? nil
    }
}

func utf8(_ string: String) -> Data { Data(string.utf8) }

func filenamesPlist(_ paths: [String]) -> Data {
    try! PropertyListSerialization.data(fromPropertyList: paths, format: .xml, options: 0)
}

let ownBundleID = "app.memopila.Memopila"

func reader(
    profiles: AppProfiles = AppProfiles(),
    policy: FormatPolicy = FormatPolicy(),
    frontmost: String? = "com.example.editor",
    ignoreRemote: Bool = false,
    saveAnyway: Bool = false,
    secretPolicy: SecretPolicy = .off,
    now: Date = Date(timeIntervalSince1970: 1_000)
) -> SnapshotReader {
    SnapshotReader(
        context: CaptureContext(
            profiles: profiles,
            formatPolicy: policy,
            frontmostBundleID: frontmost,
            ownBundleID: ownBundleID,
            ignoreRemoteClipboard: ignoreRemote,
            saveAnyway: saveAnyway,
            secretPolicy: secretPolicy
        ),
        now: { now }
    )
}

extension SnapshotReadOutcome {
    var snapshot: OwnedSnapshot? {
        if case .captured(let snapshot) = self { return snapshot }
        return nil
    }
}
