import MemopilaCore
import SwiftUI

/// Docked under the image while sampling or after a pin (PLAN §8.5 eyedropper).
struct SampledColorPane: View {
    let pinned: ColorValues?
    let isPicking: Bool
    let hover: ColorValues?
    @Binding var format: ColorPasteFormat
    let copy: (ColorValues, ColorPasteFormat) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(alignment: .center, spacing: 12) {
                // While picking, the header tracks the cursor; Copy always uses the pin below.
                ColorSwatch(hex: (isPicking ? (hover ?? pinned) : pinned)?.hex, cornerRadius: 8)
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Label("Sampled Colour", systemImage: "eyedropper")
                        .font(.callout.weight(.semibold))
                    if isPicking, hover != nil, pinned != nil {
                        Text(String(localized: "Preview — pin is below"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if isPicking, pinned == nil {
                        Text(String(localized: "Click a pixel to sample · Esc cancels"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if pinned != nil {
                        Text(String(localized: "Pick a format, then Copy"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            if let pinned {
                Divider()
                ColorFormatRows(values: pinned, format: $format) {
                    copy(pinned, format)
                }
                .padding(12)
            }
        }
        .background(.bar)
    }
}
