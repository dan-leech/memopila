import AppKit
import MemopilaCore
import MemopilaServices
import SwiftUI

/// Settings window (PLAN §8.7).
struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView(selection: $model.settingsTab) {
            GeneralSettings(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            CaptureSettings(model: model)
                .tabItem { Label("Capture", systemImage: "list.clipboard") }
                .tag(SettingsTab.capture)
            AppsSettings(model: model)
                .tabItem { Label("Apps", systemImage: "square.grid.2x2") }
                .tag(SettingsTab.apps)
            FormatsSettings(model: model)
                .tabItem { Label("Formats", systemImage: "doc.on.doc") }
                .tag(SettingsTab.formats)
            RecognitionSettings(settings: model.settings)
                .tabItem { Label("Text Recognition", systemImage: "text.viewfinder") }
                .tag(SettingsTab.recognition)
            StorageSettings(model: model)
                .tabItem { Label("Storage", systemImage: "internaldrive") }
                .tag(SettingsTab.storage)
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(SettingsTab.about)
        }
        .frame(width: 680, height: 500)
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
                Text("The shortcut needs ⌘ or ⌃. While Memopila holds ⌥⌘V it replaces Finder's Move Item Here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                if let error = settings.launchAtLoginError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Toggle("Show Dock icon", isOn: $settings.showDockIcon)
                    .onChange(of: settings.showDockIcon) { _, _ in model.applyActivationPolicy() }
            }
            Section("Paste After Restore") {
                Toggle("Paste into the previous app after restoring", isOn: $settings.pasteAfterRestore)
                    .onChange(of: settings.pasteAfterRestore) { _, enabled in
                        if enabled, !AccessibilityBridge.isTrusted { AccessibilityBridge.requestTrust() }
                    }
                TimelineView(.periodic(from: .now, by: 2)) { _ in
                    let trusted = AccessibilityBridge.isTrusted
                    HStack {
                        Label(
                            trusted ? String(localized: "Accessibility access is allowed.") : String(localized: "Pasting needs Accessibility access."),
                            systemImage: trusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(trusted ? Color.green : Color.orange)
                        Spacer()
                        if !trusted {
                            Button("Open Accessibility Settings") { AccessibilityBridge.openSettings() }
                        }
                    }
                    .font(.callout)
                }
                Text("Restore still works without it. When allowed, Memopila also records the title of the window you copied from.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Records the next key press with ⌘ or ⌃; Esc cancels (§2).
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

// MARK: - Capture

private struct CaptureSettings: View {
    let model: AppModel

    private var monitor: ClipboardMonitor { model.monitor }

    var body: some View {
        @Bindable var settings = model.settings
        return Form {
            Section("Clipboard Access") {
                LabeledContent("Status") {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(accessDescription)
                        switch monitor.access {
                        case .needsEnable:
                            Button("Enable Capture") { monitor.enableCapture() }
                            if let hint = monitor.enableHint { Text(hint).font(.caption).foregroundStyle(.secondary) }
                        case .ask, .denied:
                            HStack {
                                Button("Open System Settings") { PasteboardAccess.openSystemSettings() }
                                Button("Check Again") { monitor.refreshAccess() }
                            }
                        case .allowed:
                            EmptyView()
                        }
                    }
                }
                Text("macOS asks before apps read the clipboard in the background. Choose Always Allow for Memopila; other clipboard managers can compete for the same access.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Pause and Skip") {
                LabeledContent("Pause or resume capture") { ShortcutRecorder(model: model, role: .pause) }
                LabeledContent("Skip next copy") { ShortcutRecorder(model: model, role: .skip) }
                Text("Content copied while capture is paused or skipped is never read.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Source App") {
                Picker("Identify the source app", selection: $settings.identityMode) {
                    Text("Standard: marker or frontmost app").tag(IdentityMode.standard)
                    Text("Strict: marker only").tag(IdentityMode.strict)
                }
                Text("Standard uses the source marker some apps add, else the frontmost app. Strict trusts only the marker: while any app is set to Don't Save, copies without a marker are skipped. Neither is a security boundary.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Ignore content from other devices (Universal Clipboard)", isOn: $settings.ignoreRemoteClipboard)
            }
            SecretsSection(settings: model.settings)
        }
        .formStyle(.grouped)
    }

    private var accessDescription: String {
        switch monitor.access {
        case .allowed: String(localized: "Allowed")
        case .needsEnable: String(localized: "Not enabled yet")
        case .ask: String(localized: "Asks every time — choose Always Allow in System Settings")
        case .denied: String(localized: "Denied in System Settings")
        }
    }
}

// MARK: - Secrets (§3.10)

private struct SecretsSection: View {
    let settings: SettingsStore
    private static let presets = [15, 60, 480, 1_440]

    var body: some View {
        @Bindable var bindable = settings
        let store = settings
        return Section("Secrets") {
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
            Text("Tokens, keys, JWTs and card numbers are recognized on this Mac. Saved secrets are masked on cards (open the preview to see one) and deleted on time; ⌘D keeps one for good.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
                Text("Runs on this Mac only, one image at a time in the background. Found text is searchable and can be copied from the preview.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Languages") {
                Text(String(localized: "Used: \(settings.effectiveRecognitionLanguages.map(Self.languageName).joined(separator: ", "))"))
                    .font(.callout)
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

// MARK: - Storage (§6)

private struct StorageSettings: View {
    let model: AppModel
    @State private var isConfirmingClear = false
    @State private var clearScope: ClearScope = .nonFavorites
    @State private var count: Int?

    var body: some View {
        @Bindable var settings = model.settings
        return Form {
            Section("History") {
                Stepper(value: $settings.maxCount, in: RetentionPlanner.maxCountRange, step: 50) {
                    LabeledContent("Keep up to", value: String(localized: "\(settings.maxCount) items"))
                }
                Stepper(value: $settings.maxAgeDays, in: SettingsStore.maxAgeRange) {
                    LabeledContent("Delete items older than", value: String(localized: "\(settings.maxAgeDays) days"))
                }
                Text("Favorites are never deleted automatically. Total stored size is limited to 512 MB; when it is full, the oldest items make room.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let count {
                    LabeledContent("Items in history", value: "\(count)")
                }
            }
            Section("Clear History") {
                HStack {
                    Button("Clear History…") {
                        clearScope = .nonFavorites
                        isConfirmingClear = true
                    }
                    Button("Clear Everything, Including Favorites…", role: .destructive) {
                        clearScope = .all
                        isConfirmingClear = true
                    }
                }
                .disabled(model.monitor.isBusy)
            }
        }
        .formStyle(.grouped)
        .task { count = try? await model.store.count(HistoryQuery()) }
        .confirmationDialog(
            clearScope == .all ? String(localized: "Delete all items, including favorites?") : String(localized: "Delete all items except favorites?"),
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button(clearScope == .all ? String(localized: "Delete Everything") : String(localized: "Clear History"), role: .destructive) {
                model.clear(clearScope)
                Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    count = try? await model.store.count(HistoryQuery())
                }
            }
        } message: {
            Text("This can't be undone.")
        }
    }
}

// MARK: - About (§8.7, §9)

private struct AboutSettings: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
            }
            Section("Privacy") {
                Text("History stays on this Mac, in ~/Library/Application Support/Memopila. It is not encrypted and is never sent anywhere.")
                Text("Apps that mark passwords and other secrets as concealed or transient are skipped. Apps that don't are not filtered: use Pause or Skip Next Copy, or set the app to Don't Save.")
                Text("Text recognition runs on this Mac. Files are stored as references, not copies.")
            }
            .font(.callout)
        }
        .formStyle(.grouped)
    }
}
