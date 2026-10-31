import AppKit
import MemopilaCore
import MemopilaServices
import SwiftUI

/// One Settings tab (PLAN §8.7); `SecondaryWindows` puts them in a window with toolbar tabs.
struct SettingsPage: View {
    static let size = CGSize(width: 700, height: 540)

    let model: AppModel
    let tab: SettingsTab

    var body: some View {
        page.frame(width: Self.size.width, height: Self.size.height)
    }

    @ViewBuilder
    private var page: some View {
        switch tab {
        case .general: GeneralSettings(model: model)
        case .history: HistorySettings(model: model)
        case .privacy: PrivacySettings(model: model)
        case .apps: AppsSettings(model: model)
        case .about: AboutSettings()
        }
    }
}

extension SettingsTab {
    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .history: String(localized: "History")
        case .privacy: String(localized: "Privacy")
        case .apps: String(localized: "Apps")
        case .about: String(localized: "About")
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .history: "clock.arrow.circlepath"
        case .privacy: "hand.raised"
        case .apps: "square.grid.2x2"
        case .about: "info.circle"
        }
    }
}

// MARK: - General

private struct GeneralSettings: View {
    let model: AppModel
    @State private var isTrusted = AccessibilityBridge.isTrusted

    var body: some View {
        @Bindable var settings = model.settings
        return Form {
            Section {
                LabeledContent("Open Memopila") { ShortcutRecorder(model: model, role: .window) }
                    .floatingHelp(String(localized: "Global hotkey to open or close the history panel (default ⌥⌘V)."))
                LabeledContent("Pause or resume capture") { ShortcutRecorder(model: model, role: .pause) }
                    .floatingHelp(String(localized: "Optional global hotkey. In the panel, ⌘. always pauses or resumes — no shortcut needed here."))
                LabeledContent("Skip next copy") { ShortcutRecorder(model: model, role: .skip) }
                    .floatingHelp(String(localized: "Optional global hotkey to skip the next copy without reading it."))
            } header: {
                Text("Shortcuts")
            } footer: {
                Text("A shortcut needs ⌘ or ⌃. Only one app can hold ⌥⌘V: quit Pasta or choose another shortcut. Pause and Skip are optional globals; ⌘. in the panel always pauses or resumes.")
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
                Toggle("Paste into the app you were in", isOn: $settings.pasteAfterCopy)
                    .onChange(of: settings.pasteAfterCopy) { _, enabled in
                        if enabled, !AccessibilityBridge.isTrusted { AccessibilityBridge.requestTrust() }
                    }
                // Checked when Memopila comes back from System Settings, not polled while the kept
                // Settings window is closed (review finding).
                LabeledContent("Accessibility") {
                    if isTrusted {
                        Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Allow in System Settings…") { AccessibilityBridge.openSettings() }
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    isTrusted = AccessibilityBridge.isTrusted
                }
            } header: {
                Text("Auto-Paste After Choosing")
            } footer: {
                Text("Choose for Clipboard (double-click, ↩ or ⌘1…⌘9) puts an item on the clipboard and takes you back to the app you were in. With this option Memopila also presses ⌘V there for you, which needs Accessibility. When allowed, Memopila also remembers the title of the window you copied from. Paste stacks also need Accessibility (and possibly Input Monitoring) so each ⌘V can advance the deal; Esc stops an armed stack. Menu Paste and Secure Input fields do not advance.")
            }

            RecognitionSections(settings: model.settings)
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
    @State private var resignObserver: NSObjectProtocol?

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

    /// Only keys typed in this window are recorded, and leaving the window ends the recording:
    /// the window is kept when closed, so `onDisappear` never came and the monitor went on
    /// swallowing every key of the app (review finding).
    private func startRecording() {
        guard let window = NSApp.keyWindow else { return }
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard event.window === window else {
                    stopRecording()
                    return false
                }
                record(event)
                return true
            }
            return consumed ? nil : event
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { stopRecording() }
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
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        monitor = nil
        resignObserver = nil
        isRecording = false
    }
}

// MARK: - History (§6)

private struct HistorySettings: View {
    let model: AppModel
    @State private var usage: HistoryUsage?
    @State private var isConfirmingClear = false
    @State private var clearScope: ClearScope = .nonFavorites
    /// The picker's value; a lower limit waits here for confirmation, since it deletes at once.
    @State private var storageChoice = 0
    @State private var isConfirmingStorage = false
    /// A lower count or age limit deletes at once too: asked first (review finding).
    @State private var countChoice = 0
    @State private var ageChoice = 0
    @State private var pendingCut: RetentionCut?

    private static let countOptions = [100, 250, 500, 1_000, 2_500, 5_000, 10_000]
    private static let ageOptions = [1, 7, 14, 30, 90, 180, 365]
    private static let storageOptions = [256, 512, 1_024, 2_048, 4_096, 8_192]

    var body: some View {
        @Bindable var settings = model.settings
        return Form {
            Section {
                Picker("Keep up to", selection: $countChoice) {
                    ForEach(Self.options(Self.countOptions, current: settings.maxCount), id: \.self) { count in
                        Text(String(localized: "\(count) items")).tag(count)
                    }
                }
                Picker("Delete items older than", selection: $ageChoice) {
                    ForEach(Self.options(Self.ageOptions, current: settings.maxAgeDays), id: \.self) { days in
                        Text(Self.ageTitle(days)).tag(days)
                    }
                }
                Picker("Storage limit", selection: $storageChoice) {
                    ForEach(Self.options(Self.storageOptions, current: settings.maxStorageMiB), id: \.self) { mib in
                        Text(ByteCount.string(mib * FormatPolicy.mebibyte)).tag(mib)
                    }
                }
            } header: {
                Text("Retention")
            } footer: {
                Text("Favorites and paste-stack members are never deleted automatically. When all items together reach the storage limit, the oldest make room; lowering it does that at once.")
            }

            Section {
                LabeledContent("Items", value: usage.map { "\($0.count)" } ?? "—")
                LabeledContent("Favorites", value: usage.map { "\($0.favorites)" } ?? "—")
                LabeledContent("Stored data") {
                    if let usage {
                        Text(String(localized: "\(ByteCount.string(usage.payloadBytes)) of \(ByteCount.string(model.settings.maxStorageBytes))"))
                    } else {
                        Text("—")
                    }
                }
                LabeledContent("Location") {
                    Button("Show in Finder") { External.reveal([ClipboardStore.defaultURL]) }
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
                Text("Clear History keeps favorites and stack members. Clear Everything removes them too.")
            }
        }
        .formStyle(.grouped)
        .task { await refreshUsage() }
        // The window is kept: refresh when it comes forward again (review finding: stale counts).
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            guard (notification.object as? NSWindow)?.identifier == SecondaryWindows.settingsIdentifier else { return }
            Task { await refreshUsage() }
        }
        .onAppear {
            storageChoice = model.settings.maxStorageMiB
            countChoice = model.settings.maxCount
            ageChoice = model.settings.maxAgeDays
        }
        .onChange(of: storageChoice) { _, mib in requestStorageLimit(mib) }
        .onChange(of: countChoice) { _, count in requestCut(.count(count)) }
        .onChange(of: ageChoice) { _, days in requestCut(.age(days)) }
        .onChange(of: pendingCut) { _, cut in
            // Cancelled: the pickers show the limits in force again.
            if cut == nil {
                countChoice = model.settings.maxCount
                ageChoice = model.settings.maxAgeDays
            }
        }
        .confirmationDialog(
            pendingCut?.title ?? "",
            isPresented: Binding(get: { pendingCut != nil }, set: { if !$0 { pendingCut = nil } }),
            titleVisibility: .visible,
            presenting: pendingCut
        ) { cut in
            Button(String(localized: "Delete Them"), role: .destructive) {
                switch cut.kind {
                case .count(let count): model.settings.maxCount = count
                case .age(let days): model.settings.maxAgeDays = days
                }
                pendingCut = nil
                Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    await refreshUsage()
                }
            }
        } message: { cut in
            Text(String(localized: "\(cut.victims) items that are not favorites or stack members (including stale stacks) are deleted now. This can't be undone."))
        }
        .onChange(of: isConfirmingStorage) { _, asking in
            // Cancelled: the picker shows the limit in force again.
            if !asking { storageChoice = model.settings.maxStorageMiB }
        }
        .confirmationDialog(String(localized: "Lower the storage limit?"), isPresented: $isConfirmingStorage, titleVisibility: .visible) {
            Button(String(localized: "Lower and Delete the Oldest Items"), role: .destructive) {
                model.settings.maxStorageMiB = storageChoice
            }
        } message: {
            Text("History is larger than the new limit. The oldest items that are not favorites or stack members are deleted until it fits; pinned items stay. This can't be undone.")
        }
        // A lower limit deletes old items; the usage shows the result.
        .onChange(of: model.settings.maxStorageMiB) { _, _ in
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                await refreshUsage()
            }
        }
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

    /// Lowering the limit below what history holds deletes old items: it asks first, also before
    /// the usage is known.
    private func requestStorageLimit(_ mib: Int) {
        guard mib > 0, mib != model.settings.maxStorageMiB else { return }
        if mib < model.settings.maxStorageMiB, usage.map({ $0.payloadBytes > mib * FormatPolicy.mebibyte }) ?? true {
            isConfirmingStorage = true
        } else {
            model.settings.maxStorageMiB = mib
        }
    }

    /// A lower count or age limit: applied at once when it deletes nothing, else asked first.
    private func requestCut(_ kind: RetentionCut.Kind) {
        let settings = model.settings
        let store = model.store
        switch kind {
        case .count(let count):
            guard count > 0, count != settings.maxCount else { return }
            guard count < settings.maxCount else { settings.maxCount = count; return }
        case .age(let days):
            guard days > 0, days != settings.maxAgeDays else { return }
            guard days < settings.maxAgeDays else { settings.maxAgeDays = days; return }
        }
        Task {
            let victims: Int
            switch kind {
            case .count(let count):
                victims = max(0, ((try? await store.countNonFavorites()) ?? count + 1) - count)
            case .age(let days):
                let maxAge = TimeInterval(days) * 86_400
                if let preview = try? await store.retentionCutPreview(maxAge: maxAge) {
                    // Records + stale stacks + cascade members (preview ≠ apply without this).
                    victims = preview.records + preview.stacks + preview.cascade
                } else {
                    victims = 1
                }
            }
            guard victims > 0 else {
                switch kind {
                case .count(let count): settings.maxCount = count
                case .age(let days): settings.maxAgeDays = days
                }
                return
            }
            pendingCut = RetentionCut(kind: kind, victims: victims, ageTitle: Self.ageTitle)
        }
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

/// A lower *Keep up to* or *Delete items older than*, waiting for confirmation.
private struct RetentionCut: Equatable {
    enum Kind: Equatable {
        case count(Int)
        case age(Int)
    }

    let kind: Kind
    let victims: Int
    let title: String

    init(kind: Kind, victims: Int, ageTitle: (Int) -> String) {
        self.kind = kind
        self.victims = victims
        switch kind {
        case .count(let count): title = String(localized: "Keep only \(count) items?")
        case .age(let days): title = String(localized: "Delete items older than \(ageTitle(days))?")
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.kind == rhs.kind && lhs.victims == rhs.victims }
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
                Label("History stays on this Mac: no account, sync or analytics.", systemImage: "laptopcomputer")
                Label("Opening HTML or a web archive from history strips remote images, stylesheets and similar loads (bytes already in the archive stay local). Clicking an http(s) or mailto link in the editor opens it outside Memopila — in your Mac’s default browser or mail app.", systemImage: "network.slash")
                Label("It is not encrypted on disk.", systemImage: "lock.open")
                Label("Copies that apps mark as concealed, such as passwords from a password manager, are never saved or shown. The panel only says that one is on the clipboard, and can clear it.", systemImage: "key")
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
            Text("Tokens, keys, JWTs and card numbers are recognized on this Mac. Saved secrets are masked on cards (Edit Record shows one) and deleted on time; ⌘D keeps one for good.")
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

/// Text recognition (§3.8), in General: one switch and the languages.
private struct RecognitionSections: View {
    let settings: SettingsStore
    @State private var supported: [String] = []

    var body: some View {
        let settings = self.settings
        Section {
            Toggle("Recognize text in images and scanned PDFs", isOn: .main(
                get: { settings.recognizeText },
                set: { settings.recognizeText = $0 }
            ))
        } header: {
            Text("Text Recognition")
        } footer: {
            Text("Runs on this Mac, one image at a time in the background. Found text is searchable and can be copied in Edit Record.")
        }
        .task { supported = await Task.detached { TextRecognizer.supportedLanguages() }.value }
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
            Text("Recognition Languages")
        }
        .disabled(!settings.recognizeText)
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
