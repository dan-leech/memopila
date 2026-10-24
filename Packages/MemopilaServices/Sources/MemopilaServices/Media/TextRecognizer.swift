import CoreGraphics
import Foundation
import PDFKit
import Vision

/// On-device text recognition for image and PDF records (PLAN §3.8). No network.
public enum TextRecognizer {
    /// Long side of the image handed to Vision (no full-size decode, §7.3).
    public static let maxPixelSize = 4_096

    public enum Failure: Error, Sendable {
        case unreadableImage
    }

    /// Recognized text, or `nil` when the image has none. PDFs with a text layer use it directly.
    public static func recognize(data: Data, isPDF: Bool, languages: [String]) throws -> String? {
        if isPDF, let text = PDFDocument(data: data)?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return text
        }
        let image = isPDF
            ? Thumbnailer.renderPDFPage(data, maxPixelSize: 2_048)?.image
            : Thumbnailer.downsampledImage(from: data, maxPixelSize: maxPixelSize)
        guard let image else { throw Failure.unreadableImage }
        return try recognize(image, languages: languages)
    }

    public static func recognize(_ image: CGImage, languages: [String]) throws -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let supported = Set(supportedLanguages())
        let preferred = languages.filter(supported.contains)
        if !preferred.isEmpty { request.recognitionLanguages = preferred }
        try VNImageRequestHandler(cgImage: image).perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Languages Vision can recognize on this macOS version, e.g. "en-US", "ru-RU". Asked once:
    /// it builds a Vision request, and Settings and every recognized image asked again on the main
    /// thread (review finding).
    public static func supportedLanguages() -> [String] {
        supported
    }

    private static let supported: [String] = {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        return (try? request.supportedRecognitionLanguages()) ?? []
    }()

    /// The user's preferred languages that Vision supports, matched by language code.
    public static func defaultLanguages(preferred: [String] = Locale.preferredLanguages) -> [String] {
        let supported = supportedLanguages()
        var result: [String] = []
        for identifier in preferred {
            let code = Locale(identifier: identifier).language.languageCode?.identifier
            if let match = supported.first(where: { $0 == identifier || Locale(identifier: $0).language.languageCode?.identifier == code }),
               !result.contains(match) {
                result.append(match)
            }
        }
        return result.isEmpty ? Array(supported.prefix(1)) : result
    }
}
