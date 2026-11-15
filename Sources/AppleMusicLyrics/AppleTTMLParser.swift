import Foundation

struct ParsedAppleTTML: Equatable {
    let lines: [LyricLine]
    let wordTiming: WordTimingQuality
}

enum AppleTTMLParser {
    /// Parses Apple's lyric TTML. Translations and transliterations that
    /// Apple embeds in `<head>` (keyed to lines by `itunes:key`) are attached
    /// to the matching lines; a translation is used only when its language
    /// matches one of `preferredLanguages`.
    static func parse(
        _ content: String,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) throws -> ParsedAppleTTML {
        guard let data = content.data(using: .utf8) else {
            throw ParseError.invalidEncoding
        }

        let delegate = TTMLDelegate(preferredLanguages: preferredLanguages)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false

        guard parser.parse() else {
            throw parser.parserError ?? ParseError.invalidDocument
        }
        return ParsedAppleTTML(
            lines: delegate.lines.sorted { $0.time < $1.time },
            wordTiming: delegate.hasTimedSpan ? .exact : .none
        )
    }

    private final class TTMLDelegate: NSObject, XMLParserDelegate {
        var lines: [LyricLine] = []
        var hasTimedSpan = false

        private var depth = 0
        private var bodyDepth: Int?
        private var line: LineBuilder?
        private var spans: [SpanBuilder] = []

        // Embedded <translations> / <transliterations> from <head>.
        private let preferredLanguages: [String]
        private var translationSets: [(language: String, texts: [String: String])] = []
        private var transliterationSets: [(language: String, texts: [String: String])] = []
        private var currentSet: (isTransliteration: Bool, language: String, texts: [String: String])?
        private var currentTextKey: String?
        private var currentTextBuffer = ""
        private var chosenTranslations: [String: String] = [:]
        private var chosenTransliterations: [String: String] = [:]

        init(preferredLanguages: [String]) {
            self.preferredLanguages = preferredLanguages
        }

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            depth += 1
            let name = localName(elementName, qualifiedName: qName)
            if name == "body" {
                bodyDepth = depth
                chooseEmbeddedSets()
                return
            }
            guard bodyDepth != nil else {
                startHeadElement(name, attributes: attributeDict)
                return
            }

            if name == "p" {
                line = LineBuilder(
                    start: time(attributeDict["begin"]),
                    end: time(attributeDict["end"]),
                    key: attribute("key", in: attributeDict)
                )
                spans.removeAll(keepingCapacity: true)
            } else if name == "span", line != nil, let start = time(attributeDict["begin"]) {
                spans.append(
                    SpanBuilder(
                        depth: depth,
                        text: "",
                        start: start,
                        end: time(attributeDict["end"])
                    )
                )
            } else if name == "br", line != nil {
                appendRaw("\n")
            }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            let name = localName(elementName, qualifiedName: qName)
            if bodyDepth == nil {
                endHeadElement(name)
                depth -= 1
                return
            }

            if name == "span", spans.last?.depth == depth, let span = spans.popLast() {
                flush(span: span)
            } else if name == "p", let line {
                finish(line: line)
                self.line = nil
                spans.removeAll(keepingCapacity: true)
            } else if name == "body", bodyDepth == depth {
                bodyDepth = nil
            }
            depth -= 1
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if currentTextKey != nil {
                currentTextBuffer += string
                return
            }
            guard line != nil else { return }
            if !spans.isEmpty {
                spans[spans.count - 1].text += string
            } else {
                appendRaw(string)
            }
        }

        private func appendRaw(_ text: String) {
            line?.pendingText += text
        }

        private func flush(span: SpanBuilder) {
            guard var line else { return }
            let rawText = normalizedWhitespace(span.text)
            guard !rawText.isEmpty else { return }

            let text = normalizedWhitespace(line.pendingText) + rawText
            line.pendingText = ""
            line.words.append(
                MutableWord(
                    text: text,
                    start: span.start,
                    end: max(span.end ?? line.end ?? span.start + 0.1, span.start + 0.01)
                )
            )
            self.line = line
            hasTimedSpan = true
        }

        private func finish(line original: LineBuilder) {
            var line = original
            if line.words.isEmpty {
                let text = normalizedWhitespace(line.pendingText)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                let start = line.start ?? 0
                line.words = [
                    MutableWord(
                        text: text,
                        start: start,
                        end: max(line.end ?? start + 0.2, start + 0.01)
                    )
                ]
            } else if !line.pendingText.isEmpty {
                line.words[line.words.count - 1].text += normalizedWhitespace(line.pendingText)
            }

            trimEdges(of: &line.words)
            guard !line.words.isEmpty else { return }
            let text = line.words.map(\.text).joined()
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let start = line.start ?? line.words[0].start
            let translation = line.key.flatMap { chosenTranslations[$0] }
            let transliteration = line.key.flatMap { chosenTransliterations[$0] }
            lines.append(
                LyricLine(
                    time: start,
                    text: text,
                    words: line.words.map {
                        LyricWord(text: $0.text, start: $0.start, end: $0.end)
                    },
                    translation: translation,
                    transliteration: transliteration
                )
            )
        }

        // MARK: Embedded translations

        private func startHeadElement(_ name: String, attributes: [String: String]) {
            switch name {
            case "translation", "transliteration":
                currentSet = (
                    isTransliteration: name == "transliteration",
                    language: attribute("lang", in: attributes) ?? "",
                    texts: [:]
                )
            case "text" where currentSet != nil:
                currentTextKey = attribute("for", in: attributes)
                currentTextBuffer = ""
            default:
                break
            }
        }

        private func endHeadElement(_ name: String) {
            switch name {
            case "text":
                if let key = currentTextKey, currentSet != nil {
                    let text = AppleTTMLParser.normalizedWhitespace(currentTextBuffer)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { currentSet?.texts[key] = text }
                }
                currentTextKey = nil
                currentTextBuffer = ""
            case "translation", "transliteration":
                if let set = currentSet, !set.texts.isEmpty {
                    if set.isTransliteration {
                        transliterationSets.append((set.language, set.texts))
                    } else {
                        translationSets.append((set.language, set.texts))
                    }
                }
                currentSet = nil
            default:
                break
            }
        }

        private func chooseEmbeddedSets() {
            let preferred = preferredLanguages.map(Self.languageCode)
            for code in preferred {
                if let match = translationSets.first(where: { Self.languageCode($0.language) == code }) {
                    chosenTranslations = match.texts
                    break
                }
            }
            chosenTransliterations = (
                transliterationSets.first { $0.language.lowercased().contains("latn") }
                    ?? transliterationSets.first
            )?.texts ?? [:]
        }

        private static func languageCode(_ identifier: String) -> String {
            identifier
                .split(whereSeparator: { $0 == "-" || $0 == "_" })
                .first
                .map { $0.lowercased() } ?? ""
        }

        /// Attribute lookup that ignores the namespace prefix ("itunes:key", "xml:lang").
        private func attribute(_ name: String, in attributes: [String: String]) -> String? {
            if let value = attributes[name] { return value }
            return attributes.first { key, _ in
                key.split(separator: ":").last.map(String.init) == name
            }?.value
        }

        private func localName(_ elementName: String, qualifiedName: String?) -> String {
            let value = qualifiedName ?? elementName
            return value.split(separator: ":").last.map(String.init) ?? value
        }
    }

    private static func time(_ raw: String?) -> TimeInterval? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasSuffix("ms"), let milliseconds = Double(value.dropLast(2)) {
            return milliseconds / 1000
        }
        if value.hasSuffix("s"), let seconds = Double(value.dropLast()) {
            return seconds
        }

        let rawParts = value.split(separator: ":")
        guard !rawParts.isEmpty, rawParts.count <= 3 else { return nil }
        let parts = rawParts.compactMap { Double($0) }
        guard parts.count == rawParts.count else { return nil }
        return parts.reversed().enumerated().reduce(0) { result, item in
            result + item.element * pow(60, Double(item.offset))
        }
    }

    fileprivate static func normalizedWhitespace(_ text: String) -> String {
        var result = ""
        var previousWasWhitespace = false
        for character in text {
            if character.isWhitespace {
                if !previousWasWhitespace { result.append(" ") }
                previousWasWhitespace = true
            } else {
                result.append(character)
                previousWasWhitespace = false
            }
        }
        return result
    }

    private static func trimEdges(of words: inout [MutableWord]) {
        guard !words.isEmpty else { return }
        words[0].text = words[0].text.replacingOccurrences(
            of: #"^\s+"#,
            with: "",
            options: .regularExpression
        )
        words[words.count - 1].text = words[words.count - 1].text.replacingOccurrences(
            of: #"\s+$"#,
            with: "",
            options: .regularExpression
        )
        words.removeAll { $0.text.isEmpty }
    }

    private struct LineBuilder {
        let start: TimeInterval?
        let end: TimeInterval?
        var key: String?
        var pendingText = ""
        var words: [MutableWord] = []
    }

    private struct SpanBuilder {
        let depth: Int
        var text: String
        let start: TimeInterval
        let end: TimeInterval?
    }

    private struct MutableWord {
        var text: String
        let start: TimeInterval
        let end: TimeInterval
    }

    enum ParseError: Error {
        case invalidEncoding
        case invalidDocument
    }
}
