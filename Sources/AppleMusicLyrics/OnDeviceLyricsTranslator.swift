import Foundation
import NaturalLanguage
import Translation

/// Adds English translations only where Apple Music's cached lyrics lack one.
/// Translation uses Apple's installed on-device language models and never
/// changes the original lyric text or its timing.
struct OnDeviceLyricsTranslator: Sendable {
    private static let targetLanguage = Locale.Language(identifier: "en")
    private let logger = DiagnosticLogger.shared

    /// The lyrics' language when macOS supports translating it to English but
    /// the language has not been downloaded yet; nil otherwise.
    static func downloadableSourceLanguage(for document: LyricsDocument) async -> String? {
        guard #available(macOS 26.0, *), document.isSynced else { return nil }
        let text = document.lines
            .filter { $0.translation == nil }
            .map(\.text)
            .joined(separator: "\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let source = recognizer.dominantLanguage, source != .english else { return nil }
        let status = await LanguageAvailability().status(
            from: Locale.Language(identifier: source.rawValue),
            to: targetLanguage
        )
        return status == .supported ? source.rawValue : nil
    }

    func addEnglishTranslations(to document: LyricsDocument) async -> LyricsDocument {
        guard #available(macOS 26.0, *),
              document.isSynced,
              !document.lines.isEmpty else {
            return document
        }

        var uniqueMissingTexts: [String] = []
        var seenTexts = Set<String>()
        for line in document.lines where line.translation == nil {
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, seenTexts.insert(text).inserted else { continue }
            uniqueMissingTexts.append(text)
        }
        guard !uniqueMissingTexts.isEmpty else { return document }

        let lyricsForDetection = uniqueMissingTexts.joined(separator: "\n")
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(lyricsForDetection)
        guard let source = recognizer.dominantLanguage,
              source != .english else {
            return document
        }

        let sourceLanguage = Locale.Language(identifier: source.rawValue)
        let targetLanguage = Self.targetLanguage
        let availability = await LanguageAvailability().status(
            from: sourceLanguage,
            to: targetLanguage
        )
        guard availability == .installed else {
            logger.info(
                "On-device lyric translation skipped; language pair not installed; "
                    + "source=\(source.rawValue); target=en; status=\(availability)"
            )
            return document
        }

        let requests = uniqueMissingTexts.enumerated().map { index, text in
            TranslationSession.Request(sourceText: text, clientIdentifier: String(index))
        }
        do {
            let session = TranslationSession(
                installedSource: sourceLanguage,
                target: targetLanguage
            )
            let responses = try await session.translations(from: requests)
            var translations: [String: String] = [:]
            for response in responses {
                guard let identifier = response.clientIdentifier,
                      let index = Int(identifier),
                      uniqueMissingTexts.indices.contains(index) else {
                    continue
                }
                let translatedText = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !translatedText.isEmpty else { continue }
                translations[uniqueMissingTexts[index]] = translatedText
            }

            let translatedDocument = LyricsTranslationMerger.applying(
                translations,
                to: document
            )
            let count = translatedDocument.lines.filter { $0.translation != nil }.count
            logger.info(
                "On-device lyric translation finished; source=\(source.rawValue); "
                    + "translatedLines=\(count)"
            )
            return translatedDocument
        } catch {
            logger.warning(
                "On-device lyric translation failed; source=\(source.rawValue); "
                    + "error=\(error.localizedDescription)"
            )
            return document
        }
    }
}

enum LyricsTranslationMerger {
    static func applying(
        _ translations: [String: String],
        to document: LyricsDocument
    ) -> LyricsDocument {
        let translatedLines = document.lines.map { line in
            guard line.translation == nil,
                  let translation = translations[line.text.trimmingCharacters(in: .whitespacesAndNewlines)],
                  !translation.isEmpty else {
                return line
            }
            return LyricLine(
                time: line.time,
                text: line.text,
                words: line.words,
                translation: translation,
                transliteration: line.transliteration
            )
        }

        guard translatedLines != document.lines else { return document }
        return LyricsDocument(
            lines: translatedLines,
            plainText: document.plainText,
            source: document.source,
            isSynced: document.isSynced,
            wordTiming: document.wordTiming,
            artworkURL: document.artworkURL
        )
    }
}
