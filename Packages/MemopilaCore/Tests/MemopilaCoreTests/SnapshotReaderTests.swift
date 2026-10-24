import Foundation
import Testing
@testable import MemopilaCore

@Suite("Snapshot reader (§3.2)")
struct SnapshotReaderTests {
    @Test func plainTextIsCaptured() throws {
        let pasteboard = FakePasteboard(changeCount: 7, items: [[(.utf8PlainText, utf8("hi"))]])
        let snapshot = try #require(reader().read(pasteboard).snapshot)
        #expect(snapshot.changeCount == 7)
        #expect(snapshot.items == [CanonicalItem([.bytes(.utf8PlainText, utf8("hi"))])])
        #expect(snapshot.contentHash == "7217a6b5d4158994c5647766b23320369824ca0998b8f7b5deb3b0eb586edd2b")
        #expect(snapshot.payloadSizeBytes == 2)
        #expect(snapshot.displayType == .text)
        #expect(snapshot.observedAt == Date(timeIntervalSince1970: 1_000))
        #expect(snapshot.identity == AppIdentity(bundleID: "com.example.editor", source: .frontmost))
    }

    @Test func concealedMarkerOnSecondItemReadsNoPayloadAtAll() {
        let pasteboard = FakePasteboard(items: [
            [(.utf8PlainText, utf8("secret"))],
            [(.utf8PlainText, utf8("x")), ("org.nspasteboard.ConcealedType", Data())],
        ])
        let outcome = reader().read(pasteboard)
        #expect(outcome == .skipped(changeCount: 1, reason: .privacyMarker("org.nspasteboard.ConcealedType")))
        #expect(outcome.marksHandled)
        #expect(pasteboard.reads.isEmpty)
    }

    @Test func changeDuringReadDiscardsEverything() {
        let pasteboard = FakePasteboard(items: [[(.utf8PlainText, utf8("a")), (.html, utf8("<b>a</b>"))]])
        pasteboard.onRead = { pasteboard, type in if type == .html { pasteboard.changeCount += 1 } }
        let outcome = reader().read(pasteboard)
        #expect(outcome == .unstable)
        #expect(!outcome.marksHandled)
    }

    @Test func skipOutcomesStillCheckStability() {
        let pasteboard = FakePasteboard(items: [[(.utf8PlainText, utf8("a")), (.source, utf8("com.a.b"))]])
        pasteboard.onRead = { pasteboard, _ in pasteboard.changeCount += 1 }
        let profiles = AppProfiles(profiles: [AppProfile(bundleID: "com.a.b", settings: ResolvedAppSettings(captureMode: .dontSave))])
        #expect(reader(profiles: profiles).read(pasteboard) == .unstable)
    }

    @Test func dontSaveAppReadsOnlyTheSourceMarker() {
        let pasteboard = FakePasteboard(items: [[(.utf8PlainText, utf8("token")), (.source, utf8("com.apple.Terminal"))]])
        let profiles = AppProfiles(profiles: [AppProfile(bundleID: "com.apple.Terminal", settings: ResolvedAppSettings(captureMode: .dontSave))])
        #expect(reader(profiles: profiles).read(pasteboard) == .skipped(changeCount: 1, reason: .dontSave))
        #expect(pasteboard.reads == [.source])
    }

    @Test func dontSaveMatchesTheFrontmostAppWhenTheMarkerIsAbsent() {
        let pasteboard = FakePasteboard(items: [[(.utf8PlainText, utf8("token"))]])
        let profiles = AppProfiles(profiles: [AppProfile(bundleID: "com.apple.Terminal", settings: ResolvedAppSettings(captureMode: .dontSave))])
        #expect(reader(profiles: profiles, frontmost: "com.apple.Terminal").read(pasteboard) == .skipped(changeCount: 1, reason: .dontSave))
        #expect(pasteboard.reads.isEmpty)
    }

    @Test func strictModeSkipsUnmarkedChanges() {
        let pasteboard = FakePasteboard(items: [[(.utf8PlainText, utf8("x"))]])
        let profiles = AppProfiles(identityMode: .strict, profiles: [AppProfile(bundleID: "com.apple.Terminal", settings: ResolvedAppSettings(captureMode: .dontSave))])
        #expect(reader(profiles: profiles).read(pasteboard) == .skipped(changeCount: 1, reason: .strictIdentity))
    }

    @Test func emptyPasteboardIsSkippedWithoutACard() {
        #expect(reader().read(FakePasteboard(items: [])) == .skipped(changeCount: 1, reason: .empty))
        #expect(reader().read(FakePasteboard(items: [[(.source, utf8("com.a.b"))]])) == .skipped(changeCount: 1, reason: .empty))
    }

    @Test func onlyUnsupportedTypesIsNotSaved() {
        let pasteboard = FakePasteboard(items: [[("com.private.type", utf8("x"))]])
        let outcome = reader().read(pasteboard)
        guard case .notSaved(1, .noSupportedFormats, let change) = outcome else {
            Issue.record("unexpected \(outcome)")
            return
        }
        #expect(change.declaredTypes == ["com.private.type"])
        #expect(pasteboard.reads.isEmpty)
    }

    @Test func cumulativeOversizeStopsBeforeLaterRepresentations() {
        let mib = FormatPolicy.mebibyte
        let pasteboard = FakePasteboard(items: [[
            (.utf8PlainText, Data(count: 3 * mib)),
            (.html, Data(count: 3 * mib)),
            (.rtf, Data(count: 1)),
        ]])
        let outcome = reader(policy: FormatPolicy(defaultMaxBytes: 5 * mib)).read(pasteboard)
        guard case .notSaved(1, .tooLarge(let limit), let change) = outcome else {
            Issue.record("unexpected \(outcome)")
            return
        }
        #expect(limit == 5 * mib)
        #expect(change.knownBytes == 6 * mib)
        #expect(pasteboard.reads == [.utf8PlainText, .html], "the RTF representation must not be read")
    }

    @Test func declaredRepresentationReadFailureDiscardsTheSnapshot() {
        let pasteboard = FakePasteboard(items: [[(.utf8PlainText, utf8("a")), (.html, nil)]])
        let outcome = reader().read(pasteboard)
        #expect(outcome.marksHandled)
        guard case .notSaved(1, .readFailed(.html), _) = outcome else {
            Issue.record("unexpected \(outcome)")
            return
        }
    }

    @Test func screenshotKeepsPNGAndNeverReadsTIFF() throws {
        let pasteboard = FakePasteboard(items: [[(.png, utf8("png")), (.tiff, utf8("tiff"))]])
        let snapshot = try #require(reader().read(pasteboard).snapshot)
        #expect(pasteboard.reads == [.png])
        #expect(snapshot.displayType == .image)
        #expect(snapshot.skippedTypes.isEmpty)
    }

    @Test func screenshotIsAttributedToTheScreenshotAppNotTheFrontmostOne() throws {
        let pasteboard = FakePasteboard(items: [[(.png, utf8("png"))]])
        let snapshot = try #require(reader(screenshot: "com.apple.screenshot.launcher").read(pasteboard).snapshot)
        #expect(snapshot.identity == AppIdentity(bundleID: "com.apple.screenshot.launcher", source: .frontmost))
    }

    @Test func imageWithALinkKeepsTheFrontmostAppDuringAScreenshot() throws {
        // A browser's Copy Image carries the page URL as well; it is not a screenshot.
        let pasteboard = FakePasteboard(items: [[(.png, utf8("png")), (.url, utf8("https://example.com/a.png"))]])
        let snapshot = try #require(reader(screenshot: "com.apple.screenshot.launcher").read(pasteboard).snapshot)
        #expect(snapshot.identity == AppIdentity(bundleID: "com.example.editor", source: .frontmost))
    }

    @Test func textKeepsTheFrontmostAppDuringAScreenshot() throws {
        let pasteboard = FakePasteboard(items: [[(.utf8PlainText, utf8("hi"))]])
        let snapshot = try #require(reader(screenshot: "com.apple.screenshot.launcher").read(pasteboard).snapshot)
        #expect(snapshot.identity == AppIdentity(bundleID: "com.example.editor", source: .frontmost))
    }

    @Test func screenshotOverTheKeyPanelIsTheScreenshotAppsNotMemopilas() throws {
        // No agent was seen, but Memopila never writes an image-only copy of its own.
        let pasteboard = FakePasteboard(items: [[(.png, utf8("png"))]])
        let overPanel = try #require(reader(panelIsKey: true).read(pasteboard).snapshot)
        #expect(overPanel.identity == AppIdentity(bundleID: AppIdentity.screenshotApp, source: .frontmost))
        let overWindow = try #require(reader(frontmost: ownBundleID).read(pasteboard).snapshot)
        #expect(overWindow.identity == AppIdentity(bundleID: AppIdentity.screenshotApp, source: .frontmost))
    }

    @Test func textCopiedInTheKeyPanelStaysMemopilas() throws {
        let pasteboard = FakePasteboard(items: [[(.utf8PlainText, utf8("hi"))]])
        let snapshot = try #require(reader(panelIsKey: true).read(pasteboard).snapshot)
        #expect(snapshot.identity == AppIdentity(bundleID: ownBundleID, source: .frontmost))
    }

    @Test func imageFromTheFrontmostAppStaysItsWithoutAScreenshot() throws {
        let pasteboard = FakePasteboard(items: [[(.png, utf8("png"))]])
        let snapshot = try #require(reader().read(pasteboard).snapshot)
        #expect(snapshot.identity == AppIdentity(bundleID: "com.example.editor", source: .frontmost))
    }

    @Test func sourceMarkerWinsOverAScreenshotGuess() throws {
        let pasteboard = FakePasteboard(items: [[(.png, utf8("png")), (.source, utf8("com.example.paint"))]])
        let snapshot = try #require(reader(screenshot: "com.apple.screenshot.launcher").read(pasteboard).snapshot)
        #expect(snapshot.identity == AppIdentity(bundleID: "com.example.paint", source: .marker))
    }

    @Test func finderCopyStoresCoalescedPathsAndSkipsIcons() throws {
        let pasteboard = FakePasteboard(items: [[
            (.utf8PlainText, utf8("a b.txt")),
            (.fileURL, utf8("file:///Users/me/a%20b.txt")),
            (.filenames, filenamesPlist(["/Users/me/a b.txt"])),
            (.tiff, utf8("icon")),
        ]])
        let snapshot = try #require(reader().read(pasteboard).snapshot)
        #expect(snapshot.items == [CanonicalItem([
            .bytes(.utf8PlainText, utf8("a b.txt")),
            .files(.fileURL, ["/Users/me/a b.txt"]),
        ])])
        #expect(!pasteboard.reads.contains(.tiff))
        #expect(snapshot.displayType == .file)
    }

    @Test func multiFileCopyIsOneRecord() throws {
        let pasteboard = FakePasteboard(items: [
            [(.fileURL, utf8("file:///a.txt")), (.filenames, filenamesPlist(["/a.txt", "/b.txt"]))],
            [(.fileURL, utf8("file:///b.txt"))],
        ])
        let snapshot = try #require(reader().read(pasteboard).snapshot)
        #expect(snapshot.items == [
            CanonicalItem([.files(.fileURL, ["/a.txt"])]),
            CanonicalItem([.files(.fileURL, ["/b.txt"])]),
        ], "unequal lists: file-url wins, no union")
    }

    @Test func sourceChangeAloneKeepsTheSameHash() throws {
        let a = FakePasteboard(items: [[(.utf8PlainText, utf8("hi")), (.source, utf8("com.a.b"))]])
        let b = FakePasteboard(items: [[(.utf8PlainText, utf8("hi")), (.source, utf8("com.c.d"))]])
        let hashA = try #require(reader().read(a).snapshot).contentHash
        let hashB = try #require(reader().read(b).snapshot).contentHash
        #expect(hashA == hashB)
    }

    @Test func chromiumSourcePageIsRecordedOutsideThePayload() throws {
        let pasteboard = FakePasteboard(items: [[(.utf8PlainText, utf8("hi")), (.chromiumSourceURL, utf8("https://example.com/page"))]])
        let snapshot = try #require(reader().read(pasteboard).snapshot)
        #expect(snapshot.sourceURL == "https://example.com/page")
        #expect(snapshot.payloadSizeBytes == 2)
    }

    @Test func sourcePageIsNotRecordedWhenTheAppSettingIsOff() throws {
        let pasteboard = FakePasteboard(items: [[(.utf8PlainText, utf8("hi")), (.chromiumSourceURL, utf8("https://example.com"))]])
        let profiles = AppProfiles(defaults: ResolvedAppSettings(recordSourcePage: false))
        #expect(try #require(reader(profiles: profiles).read(pasteboard).snapshot).sourceURL == nil)
    }

    @Test func remoteClipboardIsIgnoredWhenTheSettingIsOn() {
        let pasteboard = FakePasteboard(items: [[(.utf8PlainText, utf8("hi")), (.remoteClipboard, Data())]])
        #expect(reader(ignoreRemote: true).read(pasteboard) == .skipped(changeCount: 1, reason: .remoteClipboard))
        #expect(reader(ignoreRemote: false).read(pasteboard).snapshot != nil)
    }

    @Test func saveAnywayKeepsEverythingUpToTheHardMax() throws {
        let pasteboard = FakePasteboard(items: [[("com.private.type", utf8("x")), (.tiff, utf8("t")), (.png, utf8("p"))]])
        let snapshot = try #require(reader(saveAnyway: true).read(pasteboard).snapshot)
        #expect(snapshot.items.first?.representations.map(\.type) == ["com.private.type", .tiff, .png])
    }

    @Test func skippedTypesAreReportedForTheBadge() throws {
        let pasteboard = FakePasteboard(items: [[(.utf8PlainText, utf8("hi")), ("com.private.type", utf8("x"))]])
        #expect(try #require(reader().read(pasteboard).snapshot).skippedTypes == ["com.private.type"])
    }
}
