import AppKit
import MemopilaCore
import MemopilaServices
import SwiftUI
import UniformTypeIdentifiers

/// Settings → Apps (PLAN §5.1): every app seen in history or added by hand, plus *All Apps* with the
/// size limit, the format rules for every app and the clipboard inspector (formerly a Formats tab).
struct AppsSettings: View {
    let model: AppModel
    @State private var seen: [AppSummary] = []

    private static let anyApp = "*"

    private var settings: SettingsStore { model.settings }

    private var bundleIDs: [String] {
        var result = settings.appProfiles.map(\.bundleID)
        for app in seen where !result.contains(app.bundleID) { result.append(app.bundleID) }
        return result
    }

    var body: some View {
        @Bindable var model = model
        return HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $model.settingsApp) {
                    Label("All Apps", systemImage: "square.grid.2x2").tag(Self.anyApp)
                    ForEach(bundleIDs, id: \.self) { bundleID in
                        HStack {
                            appIcon(bundleID)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(AppInfo.displayName(for: bundleID, fallback: seen.first { $0.bundleID == bundleID }?.name)).lineLimit(1)
                                Text(summary(settings.settings(for: bundleID))).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .tag(bundleID)
                    }
                }
                Divider()
                HStack {
                    HoverIconButton(
                        systemImage: "plus",
                        help: String(localized: "Add an app"),
                        recolorsLabel: false,
                        width: 22,
                        height: 20
                    ) { addApp() }
                    Spacer()
                }
                .padding(6)
            }
            .frame(width: 230)
            Divider()
            Group {
                if let bundleID = model.settingsApp, bundleID != Self.anyApp {
                    AppDetail(model: model, bundleID: bundleID, recordName: seen.first { $0.bundleID == bundleID }?.name)
                        .id(bundleID)
                } else {
                    AnyAppDetail(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { seen = (try? await model.store.apps()) ?? [] }
    }

    @ViewBuilder
    private func appIcon(_ bundleID: String) -> some View {
        if let icon = AppInfo.icon(for: bundleID) {
            Image(nsImage: icon).resizable().frame(width: 20, height: 20)
        } else {
            Image(systemName: "app").frame(width: 20, height: 20)
        }
    }

    private func summary(_ settings: ResolvedAppSettings) -> String {
        switch settings.captureMode {
        case .save: settings.sizeLimitMiB.map { String(localized: "Save · up to \($0) MB") } ?? String(localized: "Save")
        case .dontSave: String(localized: "Don't save")
        case .deleteAfter(let minutes): String(localized: "Delete after \(RetentionText.duration(minutes: minutes))")
        }
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
        if !settings.hasProfile(bundleID) { settings.updateProfile(bundleID) { _ in } }
        model.settingsApp = bundleID
    }
}

/// Capture mode picker values (§5.1).
private enum CaptureChoice: Hashable {
    case save, dontSave, minutes15, hour, day, custom

    init(_ mode: CaptureMode) {
        switch mode {
        case .save: self = .save
        case .dontSave: self = .dontSave
        case .deleteAfter(15): self = .minutes15
        case .deleteAfter(60): self = .hour
        case .deleteAfter(1_440): self = .day
        case .deleteAfter: self = .custom
        }
    }
}

private struct AppDetail: View {
    let model: AppModel
    let bundleID: String
    let recordName: String?
    @State private var existingCount = 0

    private var settings: SettingsStore { model.settings }
    private var name: String { AppInfo.displayName(for: bundleID, fallback: recordName) }

    var body: some View {
        let settings = self.settings
        let bundleID = self.bundleID
        let current = settings.settings(for: bundleID)
        return Form {
            Section {
                HStack(spacing: 10) {
                    if let icon = AppInfo.icon(for: bundleID) { Image(nsImage: icon).resizable().frame(width: 32, height: 32) }
                    VStack(alignment: .leading) {
                        Text(name).font(.headline)
                        Text(bundleID).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
            Section("Capture") {
                Picker("Copies from this app", selection: Binding.main(
                    get: { CaptureChoice(settings.settings(for: bundleID).captureMode) },
                    set: { choice in
                        settings.updateProfile(bundleID) { profile in
                            switch choice {
                            case .save: profile.captureMode = .save
                            case .dontSave: profile.captureMode = .dontSave
                            case .minutes15: profile.captureMode = .deleteAfter(minutes: 15)
                            case .hour: profile.captureMode = .deleteAfter(minutes: 60)
                            case .day: profile.captureMode = .deleteAfter(minutes: 1_440)
                            case .custom: profile.captureMode = .deleteAfter(minutes: profile.retentionMinutes ?? 240)
                            }
                        }
                    }
                )) {
                    Text("Save").tag(CaptureChoice.save)
                    Text("Don't save").tag(CaptureChoice.dontSave)
                    Divider()
                    Text("Save, delete after 15 minutes").tag(CaptureChoice.minutes15)
                    Text("Save, delete after 1 hour").tag(CaptureChoice.hour)
                    Text("Save, delete after 1 day").tag(CaptureChoice.day)
                    Text("Save, delete after…").tag(CaptureChoice.custom)
                }
                if CaptureChoice(current.captureMode) == .custom, let minutes = current.retentionMinutes {
                    Stepper(value: Binding.main(
                        get: { settings.settings(for: bundleID).retentionMinutes ?? minutes },
                        set: { value in settings.updateProfile(bundleID) { $0.captureMode = .deleteAfter(minutes: value) } }
                    ), in: 5...10_080, step: 5) {
                        LabeledContent("Delete after", value: RetentionText.duration(minutes: minutes))
                    }
                }
                if current.captureMode != .save, existingCount > 0 {
                    HStack {
                        Text(String(localized: "\(existingCount) items from \(name) are already in history."))
                            .font(.callout)
                        Spacer()
                        Button(String(localized: "Also Delete Them")) {
                            model.deleteRecords(fromApp: bundleID)
                            existingCount = 0
                        }
                    }
                }
            }
            Section("Limits and Extras") {
                Toggle("Custom size limit", isOn: Binding.main(
                    get: { settings.settings(for: bundleID).sizeLimitMiB != nil },
                    set: { isOn in settings.updateProfile(bundleID) { $0.sizeLimitMiB = isOn ? settings.maxItemMiB : nil } }
                ))
                if let limit = current.sizeLimitMiB {
                    Stepper(value: Binding.main(
                        get: { settings.settings(for: bundleID).sizeLimitMiB ?? limit },
                        set: { value in settings.updateProfile(bundleID) { $0.sizeLimitMiB = value } }
                    ), in: SettingsStore.itemMiBRange, step: 4) {
                        LabeledContent("Largest item", value: "\(limit) MB")
                    }
                }
                Toggle("Recognize text in images", isOn: Binding.main(
                    get: { settings.settings(for: bundleID).recognizeText },
                    set: { value in settings.updateProfile(bundleID) { $0.recognizeText = value } }
                ))
                Toggle("Record source page and window title", isOn: Binding.main(
                    get: { settings.settings(for: bundleID).recordSourcePage },
                    set: { value in settings.updateProfile(bundleID) { $0.recordSourcePage = value } }
                ))
            }
            Section("Format Rules for This App") {
                FormatRulesEditor(settings: settings, appBundleID: bundleID)
            }
            Section {
                Button("Remove Settings for \(name)", role: .destructive) {
                    settings.removeProfile(bundleID)
                }
                .disabled(!settings.hasProfile(bundleID) && settings.rules(for: bundleID).isEmpty)
            }
        }
        .formStyle(.grouped)
        .task(id: current.captureMode) {
            existingCount = current.captureMode == .save ? 0 : ((try? await model.store.countRecords(fromApp: bundleID)) ?? 0)
        }
    }
}

private struct AnyAppDetail: View {
    let model: AppModel

    var body: some View {
        @Bindable var settings = model.settings
        return Form {
            Section {
                Text("Defaults for apps without their own settings. Copies are always saved unless an app is set to Don't Save.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Stepper(value: $settings.maxItemMiB, in: SettingsStore.itemMiBRange, step: 4) {
                    LabeledContent("Largest item", value: "\(settings.maxItemMiB) MB")
                }
            } footer: {
                Text("Larger copies show a red “Current — not saved” card with Save Anyway. Apps can have their own limit.")
            }
            Section("Format Rules for All Apps") {
                FormatRulesEditor(settings: settings, appBundleID: nil)
            }
            ClipboardInspectorSection(model: model)
        }
        .formStyle(.grouped)
    }
}

// MARK: - Format rules (§3.2.2)

struct FormatRulesEditor: View {
    let settings: SettingsStore
    let appBundleID: String?

    private var indices: [Int] {
        settings.formatRules.indices.filter { settings.formatRules[$0].appBundleID == appBundleID }
    }

    var body: some View {
        let settings = self.settings
        if indices.isEmpty {
            Text("No rules. Formats on the default list are saved; others are skipped.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        ForEach(indices, id: \.self) { index in
            HStack {
                Picker("", selection: Binding.main(
                    get: { settings.formatRules.indices.contains(index) ? settings.formatRules[index].action : .skip },
                    set: { value in if settings.formatRules.indices.contains(index) { settings.formatRules[index].action = value } }
                )) {
                    Text("Keep").tag(FormatRule.Action.keep)
                    Text("Skip").tag(FormatRule.Action.skip)
                }
                .labelsHidden()
                .fixedSize()
                TextField("Type, e.g. com.adobe.photoshop-image", text: Binding.main(
                    get: { settings.formatRules.indices.contains(index) ? settings.formatRules[index].typePattern ?? "" : "" },
                    set: { value in
                        guard settings.formatRules.indices.contains(index) else { return }
                        // An empty pattern stays empty: the policy ignores it instead of matching every type.
                        settings.formatRules[index].typePattern = value.trimmingCharacters(in: .whitespaces)
                    }
                ))
                .font(.callout.monospaced())
                Toggle("Prefix", isOn: Binding.main(
                    get: { settings.formatRules.indices.contains(index) && settings.formatRules[index].isPrefix },
                    set: { value in if settings.formatRules.indices.contains(index) { settings.formatRules[index].isPrefix = value } }
                ))
                .toggleStyle(.checkbox)
                HoverIconButton(
                    systemImage: "minus.circle",
                    help: String(localized: "Remove rule"),
                    recolorsLabel: false,
                    width: 22,
                    height: 20
                ) {
                    if settings.formatRules.indices.contains(index) { settings.formatRules.remove(at: index) }
                }
            }
        }
        HStack {
            Button("Add Keep Rule") { settings.formatRules.append(FormatRule(appBundleID: appBundleID, typePattern: "", action: .keep)) }
            Button("Add Skip Rule") { settings.formatRules.append(FormatRule(appBundleID: appBundleID, typePattern: "", action: .skip)) }
        }
        Text("A rule for an app and a type wins over a rule for the app, which wins over a rule for a type. Prefix matches every type that starts with the text.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

// MARK: - Formats tab (§3.2.2)

/// *Inspect Current Clipboard* (§3.2.2): what each declared type of the clipboard would become.
struct ClipboardInspectorSection: View {
    let model: AppModel
    @State private var inspected: [InspectedType] = []
    @State private var inspectedLimit: Int?
    @State private var inspectApp: String = ""
    @State private var apps: [AppSummary] = []

    struct InspectedType: Identifiable {
        let id = UUID()
        let item: Int
        let type: String
        let decision: String
    }

    var body: some View {
        Section {
            HStack {
                Picker("As if copied from", selection: $inspectApp) {
                    Text("Any app").tag("")
                    ForEach(apps) { app in
                        Text(AppInfo.displayName(for: app.bundleID, fallback: app.name)).tag(app.bundleID)
                    }
                }
                Button("Inspect") { inspect() }
                    .floatingHelp(String(localized: "Lists which clipboard formats would be saved; only type names are read, not content."))
            }
            if let inspectedLimit {
                Text(String(localized: "Size limit: \(ByteCount.string(inspectedLimit))")).font(.caption)
            }
            ForEach(inspected) { entry in
                HStack {
                    Text("\(entry.item + 1)").font(.caption.monospaced()).foregroundStyle(.secondary)
                    Text(entry.type).font(.caption.monospaced()).textSelection(.enabled)
                    Spacer()
                    Text(entry.decision).font(.caption)
                }
            }
        } header: {
            Text("Inspect Current Clipboard")
        } footer: {
            Text("Which formats of what is on the clipboard now would be saved; nothing is read but the format names.")
        }
        .task { apps = (try? await model.store.apps()) ?? [] }
    }

    /// Declared types only; no content is read (§3.2.2 inspector).
    private func inspect() {
        let itemTypes = (NSPasteboard.general.pasteboardItems ?? []).map { $0.types.map { PasteboardType($0.rawValue) } }
        let app = inspectApp.isEmpty ? nil : inspectApp
        let plan = model.settings.formatPolicy.plan(
            itemTypes: itemTypes,
            app: app,
            profileSizeLimitMiB: app.map { model.settings.settings(for: $0).sizeLimitMiB } ?? nil
        )
        inspectedLimit = plan.maxBytes
        inspected = itemTypes.enumerated().flatMap { index, types in
            let kept = Set(plan.items.first { $0.sourceIndex == index }?.slots.map(\.type) ?? [])
            return types.map { type in
                let decision: String
                if type.isMetadataOnly {
                    decision = String(localized: "Metadata")
                } else if kept.contains(type) || (type.isFileReference && kept.contains(where: \.isFileReference)) {
                    decision = String(localized: "Saved")
                } else if plan.skippedTypes.contains(type) {
                    decision = String(localized: "Skipped")
                } else {
                    decision = String(localized: "Not needed (redundant)")
                }
                return InspectedType(item: index, type: type.rawValue, decision: decision)
            }
        }
    }
}
