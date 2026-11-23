import MemopilaCore
import MemopilaServices
import SwiftUI

/// HEX / RGB / HSL paste-format picker (§8.5). Copy is only for the eyedropper (no card yet).
struct ColorFormatRows: View {
    let values: ColorValues
    @Binding var format: ColorPasteFormat
    /// When true (Color record), changing the segment saves onto the card.
    var persistsOnChange = false
    /// Eyedropper only — Color records use Choose (↩) for the clipboard.
    var copy: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text(verbatim: format.string(from: values))
                    .font(.title3.monospaced())
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                if let copy {
                    Button(action: copy) {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .floatingHelp(String(localized: "Copy as a Color card; pastes \(format.string(from: values)) into text and the colour into Color Wells"))
                }
            }
            Picker(selection: $format) {
                ForEach(ColorPasteFormat.allCases) { option in
                    Text(verbatim: option.title).tag(option)
                }
            } label: {
                Text(String(localized: "Paste format"))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .floatingHelp(persistsOnChange
                ? String(localized: "Paste format for text fields — saved on this card; Choose (↩) puts it on the clipboard")
                : String(localized: "Paste format for text fields when you Copy this sample"))
        }
    }
}

/// Swatch that stays readable for translucent colours.
struct ColorSwatch: View {
    let hex: String?
    var cornerRadius: CGFloat = 14

    var body: some View {
        let color = hex.flatMap(Color.init(hex:)) ?? .clear
        let hasAlpha = (hex.flatMap(ColorValues.init(hex:))?.alpha ?? 255) < 255
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(color)
            .background {
                if hasAlpha {
                    Checkerboard().opacity(0.35).clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                }
            }
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.separator))
    }
}

enum ColorCardLabel {
    /// Stored paste string when present; else enriched HEX (system Color Picker may be UTI-only).
    static func text(preview: String, colorHex: String?) -> String {
        let trimmed = preview.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return colorHex ?? ""
    }

    /// Channels for swatch + secondary lines: paste string first, HEX cache only as fallback.
    static func values(preview: String, colorHex: String?) -> ColorValues? {
        ColorPayload.displayValues(preview: preview, colorHex: colorHex)
    }

    /// HEX for the swatch when the cache is still nil but the paste string is readable CSS.
    static func swatchHex(preview: String, colorHex: String?) -> String? {
        values(preview: preview, colorHex: colorHex)?.hex ?? colorHex
    }

    /// The other paste formats for the same sRGB — smaller grid lines so HEX/RGB/HSL cards compare.
    static func secondaryLines(preview: String, colorHex: String?) -> [String] {
        guard let values = values(preview: preview, colorHex: colorHex) else { return [] }
        let primary = text(preview: preview, colorHex: colorHex)
        let primaryFormat = ColorPasteFormat.matching(primary) ?? .hex
        return ColorPasteFormat.allCases
            .filter { $0 != primaryFormat }
            .map { $0.string(from: values) }
    }
}
