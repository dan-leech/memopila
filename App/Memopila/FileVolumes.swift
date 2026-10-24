import Darwin
import Foundation

/// File checks that cannot hang the app. A network share that has gone away (Wi-Fi change, sleep)
/// blocks every `stat` of its files for the share's timeout, 30 s or more; run in Swift's shared
/// pool, a few file cards stalled every task of the app (review finding).
enum FileVolumes {
    /// From the mount table the kernel already has (`MNT_NOWAIT` never touches the path itself).
    nonisolated static func isLocal(_ path: String) -> Bool {
        var mounts: UnsafeMutablePointer<statfs>?
        let count = getmntinfo_r_np(&mounts, MNT_NOWAIT)
        guard count > 0, let mounts else { return true }
        defer { free(mounts) }
        var best = -1
        var local = true
        for index in 0..<Int(count) {
            let entry = mounts[index]
            let point = withUnsafeBytes(of: entry.f_mntonname) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            let contains = point == "/" || path == point || path.hasPrefix(point + "/")
            guard contains, point.utf8.count > best else { continue }
            best = point.utf8.count
            local = entry.f_flags & UInt32(MNT_LOCAL) != 0
        }
        return local
    }

    /// `work` on a GCD thread, never in Swift's shared pool; `nil` when it takes longer than
    /// `seconds` (the thread finishes on its own).
    nonisolated static func run<T: Sendable>(timeout seconds: Double, _ work: @escaping @Sendable () -> T) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let once = Once()
            DispatchQueue.global(qos: .userInitiated).async {
                let value = work()
                if once.claim() { continuation.resume(returning: value) }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds) {
                if once.claim() { continuation.resume(returning: nil) }
            }
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }
}
