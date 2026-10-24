import AppKit
import MemopilaCore
import MemopilaServices
import SwiftUI

/// Settings window (PLAN §8.7). Floats above other apps until closed: Memopila has no Dock icon.
struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView(selection: $model.settingsTab) {
            GeneralSettings(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            HistorySettings(model: model)
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                .tag(SettingsTab.history)
            PrivacySettings(model: model)
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
                .tag(SettingsTab.privacy)
            AppsSettings(model: model)
                .tabItem { Label("Apps", systemImage: "square.grid.2x2") }
                .tag(SettingsTab.apps)
            FormatsSettings(model: model)
                .tabItem { Label("Formats", systemImage: "doc.on.doc") }
                .tag(SettingsTab.formats)
            RecognitionSettings(settings: model.settings)
                .tabItem { Label("Text Recognition", systemImage: "text.viewfinder") }
                .tag(SettingsTab.recognition)
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(SettingsTab.about)
        }
        .frame(width: 700, height: 540)
        .background(FloatingWindow { model.secondaryWindowDidClose() })
    }
}

// MARK: - General

private struct GeneralSettings: View {
    let model: AppModel

    var body: some View {
        @Bindable var settings = model.settings
        return Form {
            Section {
                LabeledContent("Open Memopila") { ShortcutRecorder(model: model, role: .window) }
                LabeledContent("Pause or resume capture") { ShortcutRecorder(model: model, role: .pause) }
                LabeledContent("Skip next copy") { ShortcutRecorder(model: model, role: .skip) }
            } header: {
                Text("Shortcuts")
            } footer: {
                Text("A shortcut needs ⌘ or ⌃. Only one app can hold ⌥⌘V: quit Pasta or choose another shortcut.")
            }

            Section {
                Picker("Grid", selection: $settings.gridSize) {
                    ForEach(GridSize.presets, id: \.self) { size in
                        Text(size.title).tag(size)
                    }
                }
            } header: {
                Text("Window")
            } footer: {
                Text("How many cards fit across and down; cards resize with the window. ⌘+ and ⌘− in the window change it too.")
            }

            Section {
                AccessStatusRow(monitor: model.monitor)
            } header: {
                Text("Clipboard Access")
            } footer: {
                Text("macOS asks before apps read the clipboard in the background. Choose Always Allow for Memopila.")
            }

            Section {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                if let error = settings.launchAtLoginError {
                    Text(error).foregroundStyle(.red)
                }
            } header: {
                Text("Startup")
            }

            Section {
                Toggle("Paste into the previous app after copying", isOn: $settings.pasteAfterRestore)
                    .onChange(of: settings.pasteAfterRestore) { _, enabled in
                        if enabled, !AccessibilityBridge.isTrusted { AccessibilityBridge.requestTrust() }
                    }
                TimelineView(.periodic(from: .now, by: 2)) { _ in
                    let trusted = AccessibilityBridge.isTrusted
                    LabeledContent("Accessibility") {
                        if trusted {
                            Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Button("Allow in System Settings…") { AccessibilityBridge.openSettings() }
                        }
                    }
                }
            } header: {
                Text("Paste After Restore")
            } footer: {
                Text("Copying works without Accessibility. When allowed, Memopila also remembers the title of the window you copied from.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct AccessStatusRow: View {
    let monitor: ClipboardMonitor

    var body: some View {
        LabeledContent("Status") {
            HStack(spacing: 8) {
                switch monitor.access {
                case .allowed:
                    Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .needsEnable:
                    Text("Not enabled yet").foregroundStyle(.secondary)
                    Button("Enable Capture") { monitor.enableCapture() }
                case .ask:
                    Text("Asks every time").foregroundStyle(.orange)
                    Button("Open System Settings") { PasteboardAccess.openSystemSettings() }
                    Button("Check Again") { monitor.refreshAccess() }
                case .denied:
                    Text("Denied").foregroundStyle(.red)
                    Button("Open System Settings") { PasteboardAccess.openSystemSettings() }
                    Button("Check Again") { monitor.refreshAccess() }
                }
            }
        }
        if let hint = monitor.enableHint, monitor.access == .needsEnable {
            Text(hint).foregroundStyle(.secondary)
        }
    }
}

struct ShortcutRecorder: View {
    let model: AppModel
    let role: HotKeyRole
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack {
                Button {
                    isRecording ? stopRecording() : startRecording()
                } label: {
                    if isRecording {
                        Text("Press a shortcut…")
                    } else if let shortcut = model.shortcut(for: role) {
                        Text(verbatim: shortcut.displayString)
                    } else {
                        Text("Record Shortcut")
                    }
                }
                if role == .window {
                    if model.settings.shortcut != .defaultShortcut {
                        Button("Reset") { model.setShortcut(.defaultShortcut, for: role) }
                    }
                } else if model.shortcut(for: role) != nil {
                    Button("Clear") { model.setShortcut(nil, for: role) }
                }
            }
            if let error = model.hotKeyErrors[role] {
                Text(error).font(.caption).foregroundStyle(.red).multilineTextAlignment(.trailing)
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { record(event) }
            return nil
        }
    }

    private func record(_ event: NSEvent) {
        if Int(event.keyCode) == 53 {
            stopRecording()
            return
        }
        guard let shortcut = HotKeyCenter.Shortcut(event: event) else { return }
        model.setShortcut(shortcut, for: role)
        stopRecording()
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }
}

// MARK: - History (§6)

private struct HistorySettings: View {
    let model: AppModel
    @State private var usage: HistoryUsage?
    @State private var isConfirmingClear = false
    @State private var clearScope: ClearScope = .nonFavorites

    private static let countOptions = [100, 250, 500, 1_000, 2_500, 5_000, 10_000]
    private static let ageOptions = [1, 7, 14, 30, 90, 180, 365]

    var body: some View {
        @Bindable var settings = model.settings
        return Form {
            Section {
                Picker("Keep up to", selection: $settings.maxCount) {
                    ForEach(Self.options(Self.countOptions, current: settings.maxCount), id: \.self) { count in
                        Text(String(localized: "\(count) items")).tag(count)
                    }
                }
                Picker("Delete items older than", selection: $settings.maxAgeDays) {
                    ForEach(Self.options(Self.ageOptions, current: settings.maxAgeDays), id: \.self) { days in
                        Text(Self.ageTitle(days)).tag(days)
                    }
                }
            } header: {
                Text("Retention")
            } footer: {
                Text("Favorites are never deleted automatically. All items together are limited to 512 MB; when that is full, the oldest make room.")
            }

            Section {
                LabeledContent("Items", value: usage.map { "\($0.count)" } ?? "—")
                LabeledContent("Favorites", value: usage.map { "\($0.favorites)" } ?? "—")
                LabeledContent("Stored data") {
                    if let usage {
                        Text(String(localized: "\(ByteCount.string(usage.payloadBytes)) of \(ByteCount.string(RetentionPlanner.defaultMaxStorageBytes))"))
                    } else {
                        Text("—")
                    }
                }
                LabeledContent("Location") {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([ClipboardStore.defaultURL]) }
                }
            } header: {
                Text("Usage")
            }

            Section {
                HStack {
                    Button("Clear History…") {
                        clearScope = .nonFavorites
                        isConfirmingClear = true
                    }
                    Button("Clear Everything…", role: .destructive) {
                        clearScope = .all
                        isConfirmingClear = true
                    }
                }
                .disabled(model.monitor.isBusy)
            } header: {
                Text("Clear")
            } footer: {
                Text("Clear History keeps favorites. Clear Everything removes them too.")
            }
        }
        .formStyle(.grouped)
        .task { await refreshUsage() }
        .confirmationDialog(
            clearScope == .all ? String(localized: "Delete all items, including favorites?") : String(localized: "Delete all items except favorites?"),
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button(clearScope == .all ? String(localized: "Delete Everything") : String(localized: "Clear History"), role: .destructive) {
                model.clear(clearScope)
                Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    await refreshUsage()
                }
            }
        } message: {
            Text("This can't be undone.")
        }
    }

    private func refreshUsage() async {
        usage = try? await model.store.usage()
    }

    /// The presets plus the current value when it was set elsewhere.
    private static func options(_ presets: [Int], current: Int) -> [Int] {
        presets.contains(current) ? presets : (presets + [current]).sorted()
    }

    private static func ageTitle(_ days: Int) -> String {
        switch days {
        case 1: String(localized: "1 day")
        case 7: String(localized: "1 week")
        case 14: String(localized: "2 weeks")
        case 90: String(localized: "3 months")
        case 180: String(localized: "6 months")
        case 365: String(localized: "1 year")
        default: String(localized: "\(days) days")
        }
    }
}

// MARK: - Privacy (§3.10, §5, §9)

private struct PrivacySettings: View {
    let model: AppModel

    var body: some View {
        @Bindable var settings = model.settings
        return Form {
            SecretsSection(settings: model.settings)

            Section {
                Picker("Identify the source app", selection: $settings.identityMode) {
                    Text("Standard: marker or frontmost app").tag(IdentityMode.standard)
                    Text("Strict: marker only").tag(IdentityMode.strict)
                }
                Toggle("Ignore content from other devices (Universal Clipboard)", isOn: $settings.ignoreRemoteClipboard)
            } header: {
                Text("Source App")
            } footer: {
                Text("Standard uses the marker some apps add, else the frontmost app. Strict trusts only the marker: while any app is set to Don't Save, unmarked copies are skipped. Neither is a security boundary.")
            }

            Section {
                Label("History stays on this Mac and is never sent anywhere.", systemImage: "laptopcomputer")
                Label("It is not encrypted on disk.", systemImage: "lock.open")
                Label("Copies that apps mark as concealed, such as passwords from a password manager, are always skipped.", systemImage: "key")
                Label("For anything else, use Pause, Skip Next Copy, or set the app to Don't Save.", systemImage: "hand.raised")
            } header: {
                Text("Your Data")
            }
        }
        .formStyle(.grouped)
    }
}

private struct SecretsSection: View {
    let settings: SettingsStore
    private static let presets = [15, 60, 480, 1_440]

    var body: some View {
        @Bindable var bindable = settings
        let store = settings
        return Section {
            Picker("When a copy contains a secret", selection: $bindable.secretPolicy) {
                Text("Save as usual").tag(SecretPolicy.off)
                Text("Don't save").tag(SecretPolicy.dontSave)
                Divider()
                ForEach(Self.presets, id: \.self) { minutes in
                    Text(String(localized: "Save, delete after \(RetentionText.duration(minutes: minutes))"))
                        .tag(SecretPolicy.deleteAfter(minutes: minutes))
                }
                if case .deleteAfter(let minutes) = settings.secretPolicy, !Self.presets.contains(minutes) {
                    Text(String(localized: "Save, delete after \(RetentionText.duration(minutes: minutes))"))
                        .tag(settings.secretPolicy)
                }
            }
            if case .deleteAfter(let minutes) = settings.secretPolicy {
                Stepper(value: Binding.main(
                    get: { minutes },
                    set: { store.secretPolicy = .deleteAfter(minutes: $0) }
                ), in: 5...10_080, step: 15) {
                    LabeledContent("Delete after", value: RetentionText.duration(minutes: minutes))
                }
            }
            DisclosureGroup("Recognized types") {
                ForEach(SecretKind.allCases, id: \.self) { kind in
                    Toggle(kind.title, isOn: Binding.main(
                        get: { !store.disabledSecretKinds.contains(kind) },
                        set: { isOn in
                            if isOn { store.disabledSecretKinds.remove(kind) } else { store.disabledSecretKinds.insert(kind) }
                        }
                    ))
                }
            }
            .disabled(settings.secretPolicy == .off)
        } header: {
            Text("Secrets")
        } footer: {
            Text("Tokens, keys, JWTs and card numbers are recognized on this Mac. Saved secrets are masked on cards (open the preview to see one) and deleted on time; ⌘D keeps one for good.")
        }
    }
}

extension SecretKind {
    var title: String {
        switch self {
        case .privateKey: String(localized: "Private keys")
        case .jwt: String(localized: "JWTs")
        case .githubToken: String(localized: "GitHub tokens")
        case .gitlabToken: String(localized: "GitLab tokens")
        case .awsAccessKey: String(localized: "AWS access keys")
        case .slackToken: String(localized: "Slack tokens and webhooks")
        case .stripeKey: String(localized: "Stripe keys")
        case .googleAPIKey: String(localized: "Google API keys")
        case .openAIKey: String(localized: "OpenAI keys")
        case .anthropicKey: String(localized: "Anthropic keys")
        case .npmToken: String(localized: "npm tokens")
        case .creditCard: String(localized: "Card numbers")
        }
    }

    /// Singular label for a card.
    var cardTitle: String {
        switch self {
        case .privateKey: String(localized: "Private key")
        case .jwt: String(localized: "JWT")
        case .githubToken: String(localized: "GitHub token")
        case .gitlabToken: String(localized: "GitLab token")
        case .awsAccessKey: String(localized: "AWS access key")
        case .slackToken: String(localized: "Slack token")
        case .stripeKey: String(localized: "Stripe key")
        case .googleAPIKey: String(localized: "Google API key")
        case .openAIKey: String(localized: "OpenAI key")
        case .anthropicKey: String(localized: "Anthropic key")
        case .npmToken: String(localized: "npm token")
        case .creditCard: String(localized: "Card number")
        }
    }
}

// MARK: - Text recognition (§3.8)

private struct RecognitionSettings: View {
    let settings: SettingsStore
    @State private var supported: [String] = []

    var body: some View {
        @Bindable var bindable = settings
        let settings = self.settings
        return Form {
            Section {
                Toggle("Recognize text in images and scanned PDFs", isOn: $bindable.recognizeText)
            } footer: {
                Text("Runs on this Mac, one image at a time in the background. Found text is searchable and can be copied from the preview.")
            }
            Section {
                LabeledContent("In use", value: settings.effectiveRecognitionLanguages.map(Self.languageName).joined(separator: ", "))
                Toggle("Use my preferred languages", isOn: .main(
                    get: { settings.recognitionLanguages.isEmpty },
                    set: { useDefault in settings.recognitionLanguages = useDefault ? [] : settings.effectiveRecognitionLanguages }
                ))
                if !settings.recognitionLanguages.isEmpty {
                    ForEach(supported, id: \.self) { language in
                        Toggle(Self.languageName(language), isOn: .main(
                            get: { settings.recognitionLanguages.contains(language) },
                            set: { isOn in
                                if isOn {
                                    settings.recognitionLanguages.append(language)
                                } else if settings.recognitionLanguages.count > 1 {
                                    settings.recognitionLanguages.removeAll { $0 == language }
                                }
                            }
                        ))
                    }
                }
            } header: {
                Text("Languages")
            }
            .disabled(!settings.recognizeText)
        }
        .formStyle(.grouped)
        .task { supported = await Task.detached { TextRecognizer.supportedLanguages() }.value }
    }

    private static func languageName(_ identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }
}

// MARK: - About

private struct AboutSettings: View {
    private static let repository = URL(string: "https://github.com/dan-leech/memopila")
    private static let issues = URL(string: "https://github.com/dan-leech/memopila/issues")

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Memopila").font(.largeTitle.bold())
            Text(String(localized: "Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")"))
                .foregroundStyle(.secondary)
            Text("Clipboard history that stays on your Mac.")
                .padding(.top, 4)
            HStack(spacing: 16) {
                if let repository = Self.repository { Link("Source on GitHub", destination: repository) }
                if let issues = Self.issues { Link("Report an Issue", destination: issues) }
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
