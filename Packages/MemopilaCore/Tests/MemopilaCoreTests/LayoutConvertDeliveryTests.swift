import Foundation
import Testing
@testable import MemopilaCore

@Suite("Layout convert delivery")
struct LayoutConvertDeliveryTests {
    private typealias D = LayoutConvertDelivery

    // MARK: Typing vs paste

    @Test func pastesWhatEditorsWouldAutoCloseOrTreatAsEnter() {
        for text in ["[jhjij", "хорошо]", "'nj", "\"x\"", "`", "(a)", "{b}", "<c>", "две\nстроки"] {
            #expect(D.needsPaste(text), "\(text)")
        }
    }

    @Test func typesPlainTextAndLetterKeyPunctuation() {
        for text in ["привет мир", "k.,k. nt,z", "ghbdtn;", "50%"] {
            #expect(!D.needsPaste(text), "\(text)")
        }
    }

    // MARK: VS Code empty-selection copy

    @Test func readsTheEmptySelectionFlagFromUTF8AndUTF16Blobs() {
        #expect(D.emptySelectionCopyFlag(in: Data(#"{"isFromEmptySelection": true}"#.utf8)) == true)
        let pickle = #"{"version":1,"isFromEmptySelection":false,"multicursorText":null}"#
        var utf16 = Data([8, 0, 0, 0])  // Chromium pickle header bytes before the UTF-16 payload.
        for unit in pickle.utf16 { withUnsafeBytes(of: unit.littleEndian) { utf16.append(contentsOf: $0) } }
        #expect(D.emptySelectionCopyFlag(in: utf16) == false)
        #expect(D.emptySelectionCopyFlag(in: Data("source-rfh-token".utf8)) == nil)
    }

    // MARK: One ⌫ over a selection

    @Test func classifiesTheFirstBackspace() {
        #expect(D.backspaceSemantics(removed: 6, selectionLength: 6) == .standard)
        #expect(D.backspaceSemantics(removed: 1, selectionLength: 1) == .standard)
        #expect(D.backspaceSemantics(removed: 1, selectionLength: 6) == .caretAtEnd)
        #expect(D.backspaceSemantics(removed: 7, selectionLength: 6) == .smartDelete)
        #expect(D.backspaceSemantics(removed: 8, selectionLength: 6) == .smartDelete)
        #expect(D.backspaceSemantics(removed: 9, selectionLength: 6) == .unknown)
        #expect(D.backspaceSemantics(removed: 3, selectionLength: 6) == .unknown)
        #expect(D.backspaceSemantics(removed: nil, selectionLength: 6) == .unknown)
    }

    @Test func standardDeleteRemovesExactlyTheSelection() {
        let reading = D.readDeletion(before: "say ghbdtn now", after: "say  now", selectionLength: 6, semantics: .standard)
        #expect(reading == .init(removed: "ghbdtn", understood: true))
    }

    @Test func smartDeleteGivesTheSpaceBackOnTheLeadingSide() {
        // KeePassium: one ⌫ removed 7 for a 6-char word. “␣ghbdtn” and “ghbdtn␣” leave the same
        // text; Cocoa takes the space before the word, so it goes back before the output.
        let reading = D.readDeletion(before: "a ghbdtn b", after: "a b", selectionLength: 6, semantics: .smartDelete)
        #expect(reading.understood)
        #expect(reading.leadingExtra == " ")
        #expect(reading.trailingExtra.isEmpty)
    }

    @Test func smartDeleteAtLineStartGivesTheSpaceBackOnTheTrailingSide() {
        let reading = D.readDeletion(before: "ghbdtn now", after: "now", selectionLength: 6, semantics: .smartDelete)
        #expect(reading == .init(removed: "ghbdtn ", trailingExtra: " ", understood: true))
    }

    @Test func smartDeleteThatSettledOnTheSelectionNeedsNoGiveBack() {
        let reading = D.readDeletion(before: "a ghbdtn b", after: "a  b", selectionLength: 6, semantics: .smartDelete)
        #expect(reading == .init(removed: "ghbdtn", understood: true))
    }

    @Test func smartDeleteOfNonWhitespaceIsRolledBack() {
        let reading = D.readDeletion(before: "xghbdtn", after: "", selectionLength: 6, semantics: .smartDelete)
        #expect(!reading.understood)
        #expect(reading.removed == "xghbdtn")
    }

    @Test func partialDeleteIsRolledBackWithTheRemovedBlock() {
        let reading = D.readDeletion(before: "ghbdtn", after: "ghb", selectionLength: 6, semantics: .standard)
        #expect(reading == .init(removed: "dtn", understood: false))
    }

    @Test func nonContiguousChangeIsNotUnderstood() {
        // The field changed elsewhere too (stale or edited value): no block to trust.
        let reading = D.readDeletion(before: "abc def", after: "xbc de", selectionLength: 1, semantics: .standard)
        #expect(reading == .init(removed: nil, understood: false))
    }

    @Test func nothingRemovedIsNotUnderstood() {
        let reading = D.readDeletion(before: "ghbdtn", after: "ghbdtn", selectionLength: 6, semantics: .unknown)
        #expect(reading == .init(removed: nil, understood: false))
    }

    @Test func lengthsAreUTF16() {
        // 😀 is two UTF-16 units: the selection length the app passes is UTF-16 too.
        let reading = D.readDeletion(before: "hi 😀 ghbdtn", after: "hi  ghbdtn", selectionLength: 2, semantics: .standard)
        #expect(reading == .init(removed: "😀", understood: true))
    }

    @Test func removalOffsetsListEveryAmbiguousCut() {
        // “a␣word␣b” → “a␣b”: the cut can start at either space.
        #expect(D.removalOffsets(length: 5, from: "a word b", giving: "a b") == [2, 1])
        #expect(D.contiguousRemovalOffset(length: 5, from: "a word b", giving: "a b") == 2)
        #expect(D.removalOffsets(length: 5, from: "a word b", giving: "xyz") == [])
    }
}
