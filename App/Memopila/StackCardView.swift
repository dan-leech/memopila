import MemopilaServices
import SwiftUI

/// Paste-stack card: same cell size as `CardView`; volume = 3 nested faces, ~45° cascade (§3.11 / §8.2).
struct StackCardView: View {
    let stack: StackCard
    let index: Int
    let hasCursor: Bool
    let model: AppModel
    /// Double-click on title/content only — not the footer buttons (avoids stealing heart clicks).
    var onDoubleClick: () -> Void = {}
    @State private var isHovered = false

    private static let radius: CGFloat = 9
    private static let deckDepth = 3
    /// Equal Δx/Δy → ~45°. Tiny stair — front face owns the body.
    private static let step: CGFloat = 3.5

    private var isArmed: Bool { model.stackSession.armedStackID == stack.id }
    private var isOnClipboard: Bool { model.monitor.clipboardStackID == stack.id }
    private var showsBadge: Bool { model.chooseBadgeStackID == stack.id }
    /// Membership append hover (panel drop onto this stack card — PLAN §3.11).
    private var isAppendTarget: Bool { model.stackDrag.appendHighlight == .stack(stack.id) }
    private var showsAccentRing: Bool { hasCursor || isAppendTarget }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Double-tap only here — footer hover buttons must not sit under count:2 (delays/steals clicks).
            VStack(alignment: .leading, spacing: 0) {
                titleStrip
                // One inset only — peeks live *inside* the GeometryReader (no double margin).
                cascade
                    .padding(.horizontal, 3)
                    .padding(.top, 2)
                    .padding(.bottom, 1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: onDoubleClick)
            footer
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay {
            if isAppendTarget {
                RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                    .fill(Color.accentColor.opacity(0.06))
                    .allowsHitTesting(false)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                .strokeBorder(
                    showsAccentRing ? Color.accentColor : Color.primary.opacity(isHovered ? 0.2 : 0.08),
                    lineWidth: showsAccentRing ? 3 : 1
                )
        }
        .overlay {
            if isOnClipboard {
                let inset: CGFloat = showsAccentRing ? 2 : 0
                RoundedRectangle(cornerRadius: Self.radius - inset, style: .continuous)
                    .strokeBorder(Color.green, lineWidth: 1)
                    .padding(inset)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topTrailing) {
            // Append affordance is the title-strip icon (`badge.plus`) — no second + in the corner.
            if showsBadge, !isAppendTarget {
                ChooseBadge(pasted: model.chooseBadgeWasPasted)
                    .padding(6)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if model.isCommandHeld, index < 9 {
                Text("⌘\(index + 1)")
                    .font(.caption.monospaced().bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.thickMaterial, in: Capsule())
                    .padding(6)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: Self.radius))
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(hasCursor ? .isSelected : [])
    }

    private var titleStrip: some View {
        HStack(spacing: 5) {
            Image(systemName: isAppendTarget ? "rectangle.stack.badge.plus" : "rectangle.stack.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text(stack.title.isEmpty ? String(localized: "Stack") : stack.title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 4)
            // One trailing capsule: count idle, or bolt+k/n while armed (k/n already is the size).
            titleTrailingBadge
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.12))
    }

    @ViewBuilder
    private var titleTrailingBadge: some View {
        if isArmed {
            HStack(spacing: 3) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 9, weight: .bold))
                Text(model.stackSession.progressLabel ?? "\(stack.memberCount)")
                    .font(.caption.monospacedDigit().weight(.semibold))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Color.orange.opacity(0.22), in: Capsule())
            .foregroundStyle(.orange)
            .floatingHelp(
                model.stackSession.progressLabel.map {
                    String(localized: "Armed \($0) — ⌘V pastes the next; Choose starts again from the first item")
                } ?? String(localized: "Armed — ⌘V pastes the next member")
            )
            .accessibilityLabel(
                Text(
                    [String(localized: "Armed"), model.stackSession.progressLabel ?? "\(stack.memberCount)"]
                        .joined(separator: " ")
                )
            )
        } else {
            Text("\(stack.memberCount)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Color.accentColor.opacity(0.16), in: Capsule())
                .foregroundStyle(.primary)
                .floatingHelp(String(localized: "How many cards are in this stack"))
        }
    }

    /// Front face fills almost the whole body; only a 5×5pt stair peeks on the trailing/bottom edge.
    private var cascade: some View {
        GeometryReader { geo in
            let depth = CGFloat(Self.deckDepth - 1)
            let faceW = max(48, geo.size.width - depth * Self.step)
            let faceH = max(32, geo.size.height - depth * Self.step)
            ZStack(alignment: .topLeading) {
                ForEach(0..<Self.deckDepth, id: \.self) { layer in
                    let fromBack = Self.deckDepth - 1 - layer
                    memberFace(
                        isTop: layer == Self.deckDepth - 1,
                        width: faceW,
                        height: faceH
                    )
                    .offset(x: CGFloat(fromBack) * Self.step, y: CGFloat(fromBack) * Self.step)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
    }

    private func memberFace(isTop: Bool, width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(Color(nsColor: .textBackgroundColor))
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(
                        isTop
                            ? Color(nsColor: .controlBackgroundColor)
                            : Color.primary.opacity(0.16)
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.primary.opacity(isTop ? 0.28 : 0.42), lineWidth: isTop ? 1 : 1.25)
            }
            .overlay(alignment: .topLeading) {
                if isTop {
                    topFaceContent
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Capsule().fill(Color.primary.opacity(0.2)).frame(width: 40, height: 1.5)
                        Capsule().fill(Color.primary.opacity(0.12)).frame(width: 26, height: 1.5)
                    }
                    .padding(4)
                }
            }
            .shadow(color: .black.opacity(isTop ? 0.25 : 0.38), radius: isTop ? 1 : 2, y: 1)
            .frame(width: width, height: height)
            .accessibilityHidden(!isTop)
    }

    @ViewBuilder
    private var topFaceContent: some View {
        if stack.sensitiveKind != nil {
            Text(String(localized: "Hidden"))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        } else if stack.preview.isEmpty {
            Text(String(localized: "Empty stack"))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        } else {
            Text(stack.preview)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.85))
                .lineLimit(6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var footer: some View {
        HStack(spacing: 5) {
            Text(String(localized: "Stack"))
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text("·").foregroundStyle(.tertiary)
            if isHovered, !model.isCommandHeld {
                Text(String(localized: "\(stack.memberCount) items"))
                    .lineLimit(1)
                Spacer(minLength: 2)
                hoverActions
            } else {
                Text(String(localized: "\(stack.memberCount) items"))
                    .lineLimit(1)
                Text("·").foregroundStyle(.tertiary)
                Image(systemName: ActionRegistry.dealSymbol(mode: stack.dealMode))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                if stack.loops, stack.dealMode != .shuffleRandom {
                    Image(systemName: "repeat")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Text(ActionRegistry.dealState(mode: stack.dealMode, loops: stack.loops))
                    .lineLimit(1)
                Spacer(minLength: 2)
                if stack.isFavorite {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.pink)
                        .floatingHelp(String(localized: "Favorite"))
                }
            }
        }
        .frame(height: 15)
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
    }

    private var hoverActions: some View {
        HStack(spacing: 0) {
            HoverIconButton(
                systemImage: stack.isFavorite ? "heart.fill" : "heart",
                help: stack.isFavorite
                    ? String(localized: "Remove from Favorites (⌘D)")
                    : String(localized: "Add to Favorites (⌘D)"),
                recolorsLabel: false,
                width: 22,
                height: 20,
                font: .system(size: 11, weight: .semibold),
                tint: stack.isFavorite ? .pink : .secondary
            ) { model.toggleStackFavorite(stack.id) }
            .symbolEffect(.bounce, value: stack.isFavorite)
            HoverIconButton(
                systemImage: "rectangle.stack",
                help: String(localized: "Edit Stack…"),
                recolorsLabel: false,
                width: 22,
                height: 20,
                font: .system(size: 11, weight: .semibold),
                tint: .secondary
            ) { model.openStackEditor(stack.id) }
            HoverIconMenu(
                systemImage: "ellipsis",
                help: String(localized: "More"),
                width: 22,
                height: 20,
                font: .system(size: 11, weight: .semibold)
            ) {
                ActionMenuItems(items: ActionRegistry.stackActions(stack, model: model))
            }
        }
    }

    private var accessibilityLabel: String {
        var parts = [
            String(localized: "Stack"),
            stack.title.isEmpty ? String(localized: "Stack") : stack.title,
        ]
        parts.append(String(localized: "\(stack.memberCount) items"))
        if isArmed, let label = model.stackSession.progressLabel {
            parts.append(label)
        }
        parts.append(ActionRegistry.dealState(mode: stack.dealMode, loops: stack.loops))
        if stack.isFavorite { parts.append(String(localized: "Favorite")) }
        if stack.sensitiveKind != nil {
            parts = [parts[0], parts[1], String(localized: "Hidden")]
        }
        return parts.joined(separator: ", ")
    }
}
