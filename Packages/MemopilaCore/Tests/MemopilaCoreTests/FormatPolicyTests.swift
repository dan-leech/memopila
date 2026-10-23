import Testing
@testable import MemopilaCore

@Suite("Format policy and rules (§3.2.2)")
struct FormatPolicyTests {
    let mib = FormatPolicy.mebibyte

    @Test func allowlistedTypesAreKeptInOriginalOrder() {
        let plan = FormatPolicy().plan(itemTypes: [[.html, .utf8PlainText, .rtf]], app: nil)
        #expect(plan.items == [PlannedItem(sourceIndex: 0, slots: [.bytes(.html), .bytes(.utf8PlainText), .bytes(.rtf)])])
        #expect(plan.skippedTypes.isEmpty)
    }

    @Test func unsupportedTypesAreSkippedAndReported() {
        let plan = FormatPolicy().plan(itemTypes: [[.utf8PlainText, "com.adobe.photoshop-private"]], app: "com.adobe.Photoshop")
        #expect(plan.items.first?.slots == [.bytes(.utf8PlainText)])
        #expect(plan.skippedTypes == ["com.adobe.photoshop-private"])
    }

    @Test func metadataAndMarkersAreNeverPlanned() {
        let plan = FormatPolicy().plan(itemTypes: [[.source, .chromiumSourceURL, .utf8PlainText]], app: nil)
        #expect(plan.items.first?.slots == [.bytes(.utf8PlainText)])
        #expect(plan.skippedTypes.isEmpty)
    }

    @Test func pngAndTiffByDefaultKeepsOnlyPNG() {
        let plan = FormatPolicy().plan(itemTypes: [[.tiff, .png]], app: nil)
        #expect(plan.items.first?.slots == [.bytes(.png)])
        #expect(plan.skippedTypes.isEmpty, "redundant rasters are not user-relevant skips")
    }

    @Test func rasterPreferenceOrder() {
        #expect(FormatPolicy().plan(itemTypes: [[.tiff, .jpeg, .heic]], app: nil).items.first?.slots == [.bytes(.heic)])
        #expect(FormatPolicy().plan(itemTypes: [[.png, .gif]], app: nil).items.first?.slots == [.bytes(.gif)])
        #expect(FormatPolicy().plan(itemTypes: [[.tiff]], app: nil).items.first?.slots == [.bytes(.tiff)])
    }

    @Test func pdfIsNotARedundantRaster() {
        let plan = FormatPolicy().plan(itemTypes: [[.pdf, .tiff, .png]], app: nil)
        #expect(plan.items.first?.slots == [.bytes(.pdf), .bytes(.png)])
    }

    @Test func photoshopKeepTIFFRuleBypassesRedundancy() {
        let policy = FormatPolicy(rules: [FormatRule(appBundleID: "com.adobe.Photoshop", typePattern: "public.tiff", action: .keep)])
        #expect(policy.plan(itemTypes: [[.png, .tiff]], app: "com.adobe.Photoshop").items.first?.slots == [.bytes(.png), .bytes(.tiff)])
        #expect(policy.plan(itemTypes: [[.png, .tiff]], app: "com.other.app").items.first?.slots == [.bytes(.png)])
    }

    @Test func keepRuleStoresNonAllowlistedType() {
        let policy = FormatPolicy(rules: [FormatRule(appBundleID: "com.adobe.Photoshop", typePattern: "com.adobe.", isPrefix: true, action: .keep)])
        let plan = policy.plan(itemTypes: [[.png, "com.adobe.photoshop-private"]], app: "com.adobe.Photoshop")
        #expect(plan.items.first?.slots == [.bytes(.png), .bytes("com.adobe.photoshop-private")])
        #expect(plan.skippedTypes.isEmpty)
    }

    @Test func precedenceAppAndTypeBeatsAppOnlyBeatsTypeOnly() {
        let policy = FormatPolicy(rules: [
            FormatRule(typePattern: "public.html", action: .skip),
            FormatRule(appBundleID: "com.a.b", action: .skip),
            FormatRule(appBundleID: "com.a.b", typePattern: "public.html", action: .keep),
        ])
        let plan = policy.plan(itemTypes: [[.html, .utf8PlainText]], app: "com.a.b")
        #expect(plan.items.first?.slots == [.bytes(.html)])
        #expect(plan.skippedTypes == [.utf8PlainText])

        let other = policy.plan(itemTypes: [[.html, .utf8PlainText]], app: "com.c.d")
        #expect(other.items.first?.slots == [.bytes(.utf8PlainText)])
        #expect(other.skippedTypes == [.html])
    }

    @Test func firstRuleInListOrderWinsWithinALevel() {
        let policy = FormatPolicy(rules: [
            FormatRule(typePattern: "public.html", action: .keep),
            FormatRule(typePattern: "public.html", action: .skip),
        ])
        #expect(policy.plan(itemTypes: [[.html]], app: nil).items.first?.slots == [.bytes(.html)])
    }

    @Test func ruleWithoutAppOrTypeIsIgnored() {
        let policy = FormatPolicy(rules: [FormatRule(action: .skip)])
        #expect(policy.plan(itemTypes: [[.html]], app: nil).items.first?.slots == [.bytes(.html)])
    }

    @Test func fileReferencesCoalesceIntoOneSlotAtTheFirstPosition() {
        let plan = FormatPolicy().plan(itemTypes: [[.utf8PlainText, .filenames, .fileURL, .html]], app: nil)
        #expect(plan.items.first?.slots == [
            .bytes(.utf8PlainText),
            .files(effectiveType: .fileURL, readFileURL: true, readFilenames: true),
            .bytes(.html),
        ])
    }

    @Test func imagesNextToFileReferencesAreSkipped() {
        let plan = FormatPolicy().plan(itemTypes: [[.fileURL, .tiff, .png]], app: nil)
        #expect(plan.items.first?.slots == [.files(effectiveType: .fileURL, readFileURL: true, readFilenames: false)])
        #expect(plan.skippedTypes.isEmpty)
    }

    @Test func legacyFilenamesAloneUseTheLegacyType() {
        let plan = FormatPolicy().plan(itemTypes: [[.filenames]], app: nil)
        #expect(plan.items.first?.slots == [.files(effectiveType: .filenames, readFileURL: false, readFilenames: true)])
    }

    @Test func itemsWithoutStoredTypesAreOmitted() {
        let plan = FormatPolicy().plan(itemTypes: [["com.private.type"], [.utf8PlainText]], app: nil)
        #expect(plan.items == [PlannedItem(sourceIndex: 1, slots: [.bytes(.utf8PlainText)])])
    }

    @Test func sizeLimitDefaultsAndOverrides() {
        #expect(FormatPolicy().plan(itemTypes: [[.png]], app: nil).maxBytes == 32 * mib)
        #expect(FormatPolicy(defaultMaxBytes: 8 * mib).plan(itemTypes: [[.png]], app: nil).maxBytes == 8 * mib)
        #expect(FormatPolicy().plan(itemTypes: [[.png]], app: "com.a.b", profileSizeLimitMiB: 100).maxBytes == 100 * mib)

        let policy = FormatPolicy(rules: [
            FormatRule(appBundleID: "com.a.b", typePattern: "public.tiff", action: .keep, maxSizeMiB: 200),
            FormatRule(appBundleID: "com.a.b", action: .keep, maxSizeMiB: 4),
            FormatRule(appBundleID: "com.a.b", typePattern: "public.heic", action: .keep, maxSizeMiB: 999),
        ])
        #expect(policy.plan(itemTypes: [[.tiff]], app: "com.a.b").maxBytes == 200 * mib, "largest matching value wins; heic is not declared")
        #expect(policy.plan(itemTypes: [[.png]], app: "com.a.b").maxBytes == 4 * mib, "a matching rule can lower the limit")
        #expect(policy.plan(itemTypes: [[.heic]], app: "com.a.b").maxBytes == FormatPolicy.hardMaxBytes, "never above the hard max")
    }

    @Test func saveAnywayKeepsAllDeclaredTypes() {
        let plan = FormatPolicy().plan(itemTypes: [["com.private.type", .tiff, .png]], app: nil, keepAllDeclaredTypes: true)
        #expect(plan.items.first?.slots == [.bytes("com.private.type"), .bytes(.tiff), .bytes(.png)])
    }
}
