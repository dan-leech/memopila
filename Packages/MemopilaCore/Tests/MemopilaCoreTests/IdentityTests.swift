import Testing
@testable import MemopilaCore

@Suite("Bundle identifier validator (§5)")
struct BundleIdentifierTests {
    @Test(arguments: ["com.example.app", "org.mozilla.firefox", "com.apple.Safari", "a.b", "com.my-app.Tool2"])
    func valid(_ id: String) {
        #expect(BundleIdentifier.isValid(id))
    }

    @Test(arguments: [
        "", "com", ".example.app", "com.example.", "com..example", "...", "com.example app",
        "com.example\tapp", "com.-example.app", "com.example-.app", "com.exämple.app", "com.example_app.x",
        String(repeating: "a.", count: 128) + "a",
    ])
    func invalid(_ id: String) {
        #expect(!BundleIdentifier.isValid(id))
    }
}

@Suite("Source marker resolution (§5)")
struct SourceMarkerTests {
    @Test func noItemDeclaresTheTypeIsAbsent() {
        #expect(SourceMarker.resolve([.notDeclared, .notDeclared]) == .absent)
        #expect(SourceMarker.resolve([]) == .absent)
    }

    @Test func sameValidIDOnSeveralItems() {
        #expect(SourceMarker.resolve([.value("com.a.b"), .notDeclared, .value("com.a.b")]) == .valid("com.a.b"))
    }

    @Test func conflictingIDsAreUnknown() {
        #expect(SourceMarker.resolve([.value("com.a.b"), .value("com.c.d")]) == .unknown)
    }

    @Test func declaredButUnreadableIsUnknownNotAbsent() {
        #expect(SourceMarker.resolve([.unreadable]) == .unknown)
        #expect(SourceMarker.resolve([.value("com.a.b"), .unreadable]) == .unknown)
    }

    @Test func emptyOrInvalidValueIsUnknown() {
        #expect(SourceMarker.resolve([.value("")]) == .unknown)
        #expect(SourceMarker.resolve([.value("com..x")]) == .unknown)
    }
}

@Suite("App identity and per-app admission (§5, §5.1)")
struct AppIdentityTests {
    @Test func validMarkerWins() {
        let identity = AppIdentity.resolve(marker: .valid("com.a.b"), frontmostBundleID: "com.c.d", panelIsKey: false, ownBundleID: ownBundleID)
        #expect(identity == AppIdentity(bundleID: "com.a.b", source: .marker))
    }

    @Test func unknownMarkerNeverFallsBackToFrontmost() {
        let identity = AppIdentity.resolve(marker: .unknown, frontmostBundleID: "com.c.d", panelIsKey: false, ownBundleID: ownBundleID)
        #expect(identity == .unknown)
    }

    @Test func absentMarkerUsesFrontmost() {
        let identity = AppIdentity.resolve(marker: .absent, frontmostBundleID: "com.c.d", panelIsKey: false, ownBundleID: ownBundleID)
        #expect(identity == AppIdentity(bundleID: "com.c.d", source: .frontmost))
    }

    @Test func absentMarkerWhilePanelIsKeyIsMemopila() {
        let identity = AppIdentity.resolve(marker: .absent, frontmostBundleID: "com.c.d", panelIsKey: true, ownBundleID: ownBundleID)
        #expect(identity == AppIdentity(bundleID: ownBundleID, source: .frontmost))
    }

    @Test func absentMarkerAndNoFrontmostIsUnknown() {
        #expect(AppIdentity.resolve(marker: .absent, frontmostBundleID: nil, panelIsKey: false, ownBundleID: ownBundleID) == .unknown)
    }

    @Test func standardModeSkipsFrontmostAppSetToDontSave() {
        let profiles = AppProfiles(profiles: [AppProfile(bundleID: "com.apple.Terminal", settings: ResolvedAppSettings(captureMode: .dontSave))])
        #expect(profiles.admission(for: AppIdentity(bundleID: "com.apple.Terminal", source: .frontmost)) == .skipDontSave)
        #expect(profiles.admission(for: AppIdentity(bundleID: "com.other.app", source: .frontmost)) == .capture(ResolvedAppSettings()))
    }

    @Test func strictModeSkipsUnmarkedChangesWhileAnyAppIsDontSave() {
        let terminal = AppProfile(bundleID: "com.apple.Terminal", settings: ResolvedAppSettings(captureMode: .dontSave))
        let strict = AppProfiles(identityMode: .strict, profiles: [terminal])
        #expect(strict.admission(for: AppIdentity(bundleID: "com.other.app", source: .frontmost)) == .skipStrict)
        #expect(strict.admission(for: .unknown) == .skipStrict)
        #expect(strict.admission(for: AppIdentity(bundleID: "com.other.app", source: .marker)) == .capture(ResolvedAppSettings()))

        let strictWithoutDontSave = AppProfiles(identityMode: .strict)
        #expect(strictWithoutDontSave.admission(for: .unknown) == .capture(ResolvedAppSettings()))
    }

    @Test func profileSettingsApplyToIdentity() {
        let settings = ResolvedAppSettings(captureMode: .deleteAfter(minutes: 60), sizeLimitMiB: 100, recognizeText: false, recordSourcePage: false)
        let profiles = AppProfiles(profiles: [AppProfile(bundleID: "com.apple.Terminal", settings: settings)])
        #expect(profiles.settings(for: AppIdentity(bundleID: "com.apple.Terminal", source: .frontmost)) == settings)
        #expect(profiles.settings(for: .unknown) == ResolvedAppSettings())
        #expect(settings.retentionMinutes == 60)
    }
}

@Suite("Privacy markers (§3.1)")
struct PrivacyMarkerTests {
    @Test(arguments: [
        ("org.nspasteboard.TransientType", PrivacyMarker.Kind.transient),
        ("de.petermaurer.TransientPasteboardType", .transient),
        ("com.typeit4me.clipping", .transient),
        ("Pasteboard generator type", .transient),
        ("org.nspasteboard.ConcealedType", .confidential),
        ("com.agilebits.onepassword", .confidential),
        ("org.nspasteboard.AutoGeneratedType", .autoGenerated),
    ])
    func eachIdentifierForbidsTheChange(_ identifier: String, _ kind: PrivacyMarker.Kind) {
        let hit = PrivacyMarker.firstHit(in: [[.utf8PlainText], [.html, PasteboardType(identifier)]])
        #expect(hit == PrivacyMarker.Hit(type: PasteboardType(identifier), kind: kind, itemIndex: 1))
    }

    @Test func sourceMarkerIsNotAPrivacyMarker() {
        #expect(PrivacyMarker.firstHit(in: [[.utf8PlainText, .source]]) == nil)
    }
}
