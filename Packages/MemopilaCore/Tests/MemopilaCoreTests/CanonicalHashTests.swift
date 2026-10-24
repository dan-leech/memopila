import Foundation
import Testing
@testable import MemopilaCore

@Suite("MCS1 canonical hash (§4)")
struct CanonicalHashTests {
    // Golden values from an independent Python implementation of CanonicalSnapshotEncodingV1.
    @Test func singleTextGoldenBytesAndHash() {
        let items = [CanonicalItem([.bytes(.utf8PlainText, utf8("hi"))])]
        let expectedHex = "4d4353310000000000000001000000000000000100000000000000167075626c69632e757466382d706c61696e2d7465787400000000000000026869"
        #expect(MCS1.encode(items).map { String(format: "%02x", $0) }.joined() == expectedHex)
        #expect(MCS1.contentHash(of: items) == "7217a6b5d4158994c5647766b23320369824ca0998b8f7b5deb3b0eb586edd2b")
    }

    @Test func structuralInvariantOneItemTwoRepsDiffersFromTwoItems() {
        let oneItem = [CanonicalItem([.bytes(.utf8PlainText, utf8("a")), .bytes(.html, utf8("<b>a</b>"))])]
        let twoItems = [CanonicalItem([.bytes(.utf8PlainText, utf8("a"))]), CanonicalItem([.bytes(.html, utf8("<b>a</b>"))])]
        #expect(MCS1.contentHash(of: oneItem) == "0610e71a277be4ae411fa54812681b174d5f3608793586de799f12c61d1df927")
        #expect(MCS1.contentHash(of: twoItems) == "5c42224f4c032d3f491a6bacb203d58560a3d7ca9e4ef33990f93ed1634f0949")
    }

    @Test func fileListGoldenHash() {
        let items = [CanonicalItem([.files(.fileURL, ["/Users/me/a b.txt", "/tmp/ü.txt"])])]
        #expect(MCS1.contentHash(of: items) == "b7649254d1082677bc873cfbfdbc5e77a6f3167cf093e4b120dea4e2a45564aa")
    }

    @Test func fileListEncoding() {
        let encoded = MCS1.encodeFileList(["/a"])
        #expect(Array(encoded) == [0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 2, 0x2F, 0x61])
    }

    @Test func emptyItemsAreNotEncoded() {
        let withEmpty = [CanonicalItem([]), CanonicalItem([.bytes(.utf8PlainText, utf8("hi"))])]
        #expect(MCS1.contentHash(of: withEmpty) == "7217a6b5d4158994c5647766b23320369824ca0998b8f7b5deb3b0eb586edd2b")
    }

    @Test func payloadSizeCountsBytesAndPathBytes() {
        let items = [CanonicalItem([.bytes(.utf8PlainText, utf8("abc")), .files(.fileURL, ["/ü"])])]
        #expect(MCS1.payloadSize(of: items) == 3 + 3)
    }
}

@Suite("File paths (§3.3.1)")
struct FilePathTests {
    @Test func percentEncodedSpaceIsDecodedOnce() {
        #expect(FilePathNormalizer.path(fromFileURLString: "file:///Users/me/My%20File.txt") == "/Users/me/My File.txt")
    }

    @Test func literalPercentInFilenameIsNotDoubleDecoded() {
        #expect(FilePathNormalizer.path(fromFileURLString: "file:///Users/me/a%2520b.txt") == "/Users/me/a%20b.txt")
        #expect(FilePathNormalizer.path(fromLegacyFilename: "/Users/me/a%20b.txt") == "/Users/me/a%20b.txt")
    }

    @Test func dotSegmentsAreKept() {
        #expect(FilePathNormalizer.path(fromFileURLString: "file:///a/./b/../c.txt") == "/a/./b/../c.txt")
        #expect(FilePathNormalizer.path(fromLegacyFilename: "/a/./b/../c.txt") == "/a/./b/../c.txt")
    }

    @Test func unicodeAndSpaces() {
        #expect(FilePathNormalizer.path(fromFileURLString: "file:///tmp/%C3%BC%20x.txt") == "/tmp/ü x.txt")
    }

    @Test func nonFileURLIsRejected() {
        #expect(FilePathNormalizer.path(fromFileURLString: "https://example.com/a") == nil)
    }

    @Test func sameFileThroughBothRepresentationsGivesIdenticalFileList() {
        let fromURL = FilePathNormalizer.paths(fromFileURLData: utf8("file:///Users/me/My%20File.txt"))
        let fromLegacy = FilePathNormalizer.paths(fromFilenamesPropertyList: filenamesPlist(["/Users/me/My File.txt"]))
        #expect(fromURL == fromLegacy)
        #expect(MCS1.encodeFileList(fromURL!) == MCS1.encodeFileList(fromLegacy!))
    }

    @Test func fileURLDataMayBeNULTerminated() {
        #expect(FilePathNormalizer.paths(fromFileURLData: utf8("file:///a.txt") + Data([0])) == ["/a.txt"])
    }

    @Test func coalesceEqualDifferentAndSingle() {
        #expect(FilePathNormalizer.coalesce(fileURLPaths: ["/a"], filenamesPaths: ["/a"]) == ["/a"])
        #expect(FilePathNormalizer.coalesce(fileURLPaths: ["/a"], filenamesPaths: ["/a", "/b"]) == ["/a"])
        #expect(FilePathNormalizer.coalesce(fileURLPaths: nil, filenamesPaths: ["/a", "/b"]) == ["/a", "/b"])
        #expect(FilePathNormalizer.coalesce(fileURLPaths: nil, filenamesPaths: nil) == nil)
    }

    @Test func invalidFilenamesPlistIsRejected() {
        #expect(FilePathNormalizer.paths(fromFilenamesPropertyList: utf8("not a plist")) == nil)
        #expect(FilePathNormalizer.paths(fromFilenamesPropertyList: filenamesPlist([])) == nil)
    }
}
