/// Classification for the UI only (PLAN §3.2); never used to drop representations.
public enum DisplayType: String, Sendable, Equatable, Codable, CaseIterable {
    case text
    case richText
    case url
    case image
    case pdf
    case color
    case file
    case mixed

    /// Dominant class per item (file > image > pdf > color > rich text > url > text); several different classes → mixed.
    /// Rich text only when its formatting says something (`FormattingSignificance`).
    /// Plain text that is a single web URL counts as `url`.
    public static func classify(_ items: [CanonicalItem]) -> DisplayType {
        let classes = Set(items.compactMap(dominantClass))
        guard classes.count == 1, let only = classes.first else { return .mixed }
        if only == .text, let text = TextDecoding.plainText(of: items), TextDecoding.isSingleWebURL(text) {
            return .url
        }
        return only
    }

    private static func dominantClass(of item: CanonicalItem) -> DisplayType? {
        let types = Set(item.representations.map(\.type))
        if types.contains(where: \.isFileReference) { return .file }
        if types.contains(where: \.isRasterImage) { return .image }
        if types.contains(.pdf) { return .pdf }
        if types.contains(.color) { return .color }
        // With plain text beside it, formatting that says nothing (one font in one colour) is text:
        // nearly every copy from a browser or Terminal carries RTF or HTML (owner feedback).
        if !types.isDisjoint(with: PasteboardType.richTextTypes),
           types.isDisjoint(with: PasteboardType.plainTextTypes) || FormattingSignificance.isSignificant(item) {
            return .richText
        }
        if types.contains(.url) { return .url }
        if !types.isDisjoint(with: PasteboardType.plainTextTypes) { return .text }
        return item.representations.isEmpty ? nil : .mixed
    }
}
