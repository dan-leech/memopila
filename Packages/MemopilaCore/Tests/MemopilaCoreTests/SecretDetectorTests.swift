import Foundation
import Testing
@testable import MemopilaCore

/// Sample credentials are assembled at run time so the source holds no token-shaped strings.
private enum Sample {
    static let jwt = "ey" + "JhbGciOiJIUzI1NiJ9" + "." + "ey" + "JzdWIiOiIxMjM0NTYifQ" + "." + "c2lnbmF0dXJlLXZhbHVl"
    static let github = "gh" + "p_" + String(repeating: "A1b2", count: 9)
    static let githubFineGrained = "github" + "_pat_" + String(repeating: "x9", count: 22)
    static let gitlab = "gl" + "pat-" + String(repeating: "Zz", count: 10)
    static let aws = "AK" + "IA" + "ABCDEFGHIJKLMNOP"
    static let slack = "xo" + "xb-" + "1234567890-abcdef"
    static let stripe = "sk" + "_live_" + String(repeating: "a", count: 24)
    static let google = "AI" + "za" + String(repeating: "B", count: 35)
    static let openAI = "sk" + "-proj-" + String(repeating: "q", count: 40)
    static let anthropic = "sk" + "-ant-" + "api03-" + String(repeating: "w", count: 30)
    static let npm = "np" + "m_" + String(repeating: "k", count: 36)
    static let privateKey = "-----BEGIN " + "OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEA\n-----END " + "OPENSSH PRIVATE KEY-----"
    static let visa = ["4242", "4242", "4242", "4242"].joined(separator: " ")
}

@Suite("Secret detection (§3.10)")
struct SecretDetectorTests {
    @Test(arguments: [
        (Sample.jwt, SecretKind.jwt),
        ("Authorization: Bearer " + Sample.jwt, .jwt),
        (Sample.github, .githubToken),
        (Sample.githubFineGrained, .githubToken),
        (Sample.gitlab, .gitlabToken),
        ("export AWS_ACCESS_KEY_ID=" + Sample.aws, .awsAccessKey),
        (Sample.slack, .slackToken),
        (Sample.stripe, .stripeKey),
        (Sample.google, .googleAPIKey),
        (Sample.openAI, .openAIKey),
        (Sample.anthropic, .anthropicKey),
        (Sample.npm, .npmToken),
        (Sample.privateKey, .privateKey),
        (Sample.visa, .creditCard),
        (Sample.visa.replacingOccurrences(of: " ", with: "-"), .creditCard),
    ])
    func detects(_ text: String, _ kind: SecretKind) {
        #expect(SecretDetector.detect(text) == kind)
    }

    @Test(arguments: [
        "3f786850e387550fdab836ed7e6dc881de23001b",
        "f81d4fae-7dec-11d0-a765-00a0c91e6bf6",
        "sk-short",
        "Hello, can we meet tomorrow? Bring the documents.",
        "Order 4242 4242 4242 4242 shipped to Berlin on Tuesday with the rest of the parts we discussed",
        "1234 5678 9012 3456",
        "4242 4242 4242 4241",
        "eyJ only a prefix",
        "akiaabcdefghijklmnop",
    ])
    func ignoresOrdinaryText(_ text: String) {
        #expect(SecretDetector.detect(text) == nil)
    }

    @Test func disabledKindsAreIgnored() {
        #expect(SecretDetector.detect(Sample.jwt, kinds: [.githubToken]) == nil)
        #expect(SecretDetector.detect(Sample.visa, kinds: Set(SecretKind.allCases).subtracting([.creditCard])) == nil)
        #expect(SecretDetector.detect(Sample.github, kinds: [.githubToken]) == .githubToken)
    }

    @Test func largeTextIsNotScanned() {
        let text = String(repeating: "a", count: SecretDetector.maxScannedBytes) + Sample.jwt
        #expect(SecretDetector.detect(text) == nil)
    }

    @Test func maskedPreviewHidesTheValue() {
        let masked = SecretDetector.maskedPreview(of: Sample.jwt)
        #expect(masked.hasPrefix("eyJhbGciOi"))
        #expect(!masked.contains("c2lnbmF0dXJl"))
    }

    // MARK: Reader integration

    private func jwtPasteboard() -> FakePasteboard {
        FakePasteboard(items: [[(.utf8PlainText, utf8(Sample.jwt))]])
    }

    @Test func dontSaveSkipsWithoutAContentCard() {
        let outcome = reader(secretPolicy: .dontSave).read(jwtPasteboard())
        #expect(outcome == .skipped(changeCount: 1, reason: .secret(.jwt)))
        #expect(outcome.marksHandled)
    }

    @Test func deleteAfterKeepsTheSecretWithExpiry() throws {
        let snapshot = try #require(reader(secretPolicy: .deleteAfter(minutes: 480)).read(jwtPasteboard()).snapshot)
        #expect(snapshot.sensitiveKind == .jwt)
        #expect(snapshot.settings.captureMode == .deleteAfter(minutes: 480))
    }

    @Test func shorterAppRetentionWins() throws {
        let profiles = AppProfiles(profiles: [
            AppProfile(bundleID: "com.example.editor", settings: ResolvedAppSettings(captureMode: .deleteAfter(minutes: 15))),
        ])
        let snapshot = try #require(reader(profiles: profiles, secretPolicy: .deleteAfter(minutes: 480)).read(jwtPasteboard()).snapshot)
        #expect(snapshot.settings.captureMode == .deleteAfter(minutes: 15))
    }

    @Test func offSavesAsUsual() throws {
        let snapshot = try #require(reader(secretPolicy: .off).read(jwtPasteboard()).snapshot)
        #expect(snapshot.sensitiveKind == nil)
        #expect(snapshot.settings.captureMode == .save)
    }

    @Test func ordinaryTextIsUnaffected() throws {
        let pasteboard = FakePasteboard(items: [[(.utf8PlainText, utf8("git checkout 3f786850e387550fdab836ed7e6dc881de23001b"))]])
        let snapshot = try #require(reader(secretPolicy: .dontSave).read(pasteboard).snapshot)
        #expect(snapshot.sensitiveKind == nil)
    }
}
