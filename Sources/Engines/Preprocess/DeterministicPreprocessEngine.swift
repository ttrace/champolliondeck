import Foundation
import NaturalLanguage

struct DeterministicPreprocessEngine: PreprocessEngine {
    let name: String = "deterministic-v1"

    func analyze(_ request: TranslationRequest) -> (input: TranslationInput, traces: [PreprocessTrace]) {
        let startedAt = Date()
        var traces: [PreprocessTrace] = []
        traces.append(
            PreprocessTrace(step: "experiment-mode", summary: request.experimentMode.rawValue)
        )

        let languageDetection = HeuristicLanguageDetector.detectLanguage(text: request.text)
        let detectedLanguage = languageDetection.detectedLanguageCode
        let isSupportedByAppleIntelligence = languageDetection.isSupportedByAppleIntelligence
        traces.append(
            PreprocessTrace(
                step: "language-detection",
                summary: "detected=\(detectedLanguage), ai_supported=\(isSupportedByAppleIntelligence), method=\(languageDetection.method)"
            )
        )

        let segmentation = request.experimentMode.usesSegmentation
            ? SentenceSegmenter.segment(request.text)
            : RawInputSegmenter.segment(request.text)
        traces.append(
            PreprocessTrace(step: "sentence-segmentation", summary: "segments=\(segmentation.segments.count)")
        )

        let protectedTokens = request.experimentMode.usesProtectedTokens
            ? ProtectedTokenExtractor.extract(from: request.text)
            : []
        traces.append(
            PreprocessTrace(step: "protected-token-extraction", summary: "tokens=\(protectedTokens.count)")
        )

        let glossaryMatches = request.experimentMode.usesGlossary
            ? GlossaryMatcher.match(glossary: request.glossary, in: request.text)
            : []
        traces.append(
            PreprocessTrace(step: "glossary-application", summary: "matches=\(glossaryMatches.count)")
        )

        let ambiguityHints = AmbiguityHintDetector.detect(in: request.text)
        traces.append(
            PreprocessTrace(step: "ambiguity-hinting", summary: "hints=\(ambiguityHints.count)")
        )

        let formatting = FormattingInspector.inspect(request.text)
        traces.append(
            PreprocessTrace(step: "formatting-preservation", summary: "newlines=\(formatting.newlineCount)")
        )

        let elapsedMs = Date().timeIntervalSince(startedAt) * 1000
        traces.append(
            PreprocessTrace(
                step: "deterministic-processing-time",
                summary: String(format: "%.2f ms", elapsedMs)
            )
        )

        return (
            TranslationInput(
                sourceLanguage: detectedLanguage,
                targetLanguage: request.targetLanguage,
                originalText: request.text,
                detectedLanguageCode: detectedLanguage,
                isDetectedLanguageSupportedByAppleIntelligence: isSupportedByAppleIntelligence,
                segments: segmentation.segments,
                segmentJoinersAfter: segmentation.joinersAfter,
                protectedTokens: protectedTokens,
                glossaryMatches: glossaryMatches,
                ambiguityHints: ambiguityHints,
                formatting: formatting
            ),
            traces
        )
    }
}

struct HeuristicLanguageDetectionResult {
    var detectedLanguageCode: String
    var isSupportedByAppleIntelligence: Bool
    var method: String
}

enum HeuristicLanguageDetector {
    private static let fallbackSupportedLanguageCodes: Set<String> = [
        "da", "de", "en", "es", "fr", "it", "ja", "ko",
        "nb", "nl", "pt", "sv", "tr", "vi", "zh"
    ]

    static func detectLanguage(text: String) -> HeuristicLanguageDetectionResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return HeuristicLanguageDetectionResult(
                detectedLanguageCode: "und",
                isSupportedByAppleIntelligence: false,
                method: "heuristic-empty-input"
            )
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)

        let dominant = recognizer.dominantLanguage.map { normalizeLanguageCode($0.rawValue) } ?? "und"
        let supported = supportedLanguageCodes()

        if supported.contains(dominant) {
            return HeuristicLanguageDetectionResult(
                detectedLanguageCode: dominant,
                isSupportedByAppleIntelligence: true,
                method: "heuristic-dominant-supported"
            )
        }

        let hypotheses = recognizer.languageHypotheses(withMaximum: 5)
            .map { (normalizeLanguageCode($0.key.rawValue), $0.value) }
            .sorted { $0.1 > $1.1 }

        if let supportedCandidate = hypotheses.first(where: { supported.contains($0.0) }) {
            return HeuristicLanguageDetectionResult(
                detectedLanguageCode: supportedCandidate.0,
                isSupportedByAppleIntelligence: true,
                method: "heuristic-hypothesis-supported"
            )
        }

        return HeuristicLanguageDetectionResult(
            detectedLanguageCode: dominant,
            isSupportedByAppleIntelligence: false,
            method: "heuristic-unsupported"
        )
    }

    private static func supportedLanguageCodes() -> Set<String> {
        return fallbackSupportedLanguageCodes
    }

    private static func normalizeLanguageCode(_ raw: String) -> String {
        raw
            .lowercased()
            .split(separator: "-")
            .first
            .map(String.init) ?? raw.lowercased()
    }
}

enum RawInputSegmenter {
    static func segment(_ text: String) -> SegmentationResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return SegmentationResult(segments: [], joinersAfter: [])
        }
        return SegmentationResult(
            segments: [TextSegment(index: 0, text: trimmed)],
            joinersAfter: [""]
        )
    }
}

enum SentenceSegmenter {
    static func segment(_ text: String) -> SegmentationResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return SegmentationResult(segments: [], joinersAfter: [])
        }

        let separators = separatorMatches(in: trimmed)
        if separators.isEmpty {
            return SegmentationResult(
                segments: [TextSegment(index: 0, text: trimmed)],
                joinersAfter: [""]
            )
        }

        var segments: [TextSegment] = []
        var joinersAfter: [String] = []
        var cursor = trimmed.startIndex

        for match in separators {
            let segmentRange = cursor..<match.range.lowerBound
            let segmentText = String(trimmed[segmentRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !segmentText.isEmpty {
                segments.append(TextSegment(index: segments.count, text: segmentText))
                joinersAfter.append(String(trimmed[match.range]))
            } else if !joinersAfter.isEmpty {
                joinersAfter[joinersAfter.count - 1] += String(trimmed[match.range])
            }
            cursor = match.range.upperBound
        }

        let trailingText = String(trimmed[cursor...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !trailingText.isEmpty {
            segments.append(TextSegment(index: segments.count, text: trailingText))
            joinersAfter.append("")
        }

        if segments.isEmpty {
            return SegmentationResult(
                segments: [TextSegment(index: 0, text: trimmed)],
                joinersAfter: [""]
            )
        }

        return SegmentationResult(segments: segments, joinersAfter: joinersAfter)
    }

    private static func separatorMatches(in text: String) -> [SeparatorMatch] {
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        let blankLineRegex = try! NSRegularExpression(pattern: #"\n[ \t]*\n+"#)
        let dialogueLineRegex = try! NSRegularExpression(
            pattern: #"(?m)\n(?=\s*(?:(?:[-—•*]\s+\S)|(?:[「『“"']\S)|(?:[A-Za-z][A-Za-z0-9 _-]{0,20}:\s)))"#
        )

        let blankLineMatches = blankLineRegex.matches(in: text, range: fullRange)
        let dialogueMatches = dialogueLineRegex.matches(in: text, range: fullRange)

        let allMatches = (blankLineMatches + dialogueMatches)
            .sorted { $0.range.location < $1.range.location }

        var resolved: [SeparatorMatch] = []
        for match in allMatches {
            guard let range = Range(match.range, in: text) else { continue }
            if let last = resolved.last {
                let overlaps = range.lowerBound < last.range.upperBound
                if overlaps {
                    continue
                }
            }
            resolved.append(SeparatorMatch(range: range))
        }
        return resolved
    }
}

private struct SeparatorMatch {
    let range: Range<String.Index>
}

struct SegmentationResult {
    var segments: [TextSegment]
    var joinersAfter: [String]
}

enum ProtectedTokenExtractor {
    private static let urlRegex = try! NSRegularExpression(pattern: #"https?://[^\s]+"#)
    private static let filePathRegex = try! NSRegularExpression(pattern: #"(?:~?/)?(?:[\w.-]+/)+[\w.-]+"#)
    private static let codeRegex = try! NSRegularExpression(pattern: #"`[^`]+`"#)
    private static let numberRegex = try! NSRegularExpression(pattern: #"\b\d+(?:[.,]\d+)?\b"#)
    private static let properNounRegex = try! NSRegularExpression(pattern: #"\b[A-Z][a-zA-Z]+\b"#)

    static func extract(from text: String) -> [ProtectedToken] {
        var tokens: [ProtectedToken] = []

        tokens += matches(using: urlRegex, in: text, kind: .url)
        tokens += matches(using: filePathRegex, in: text, kind: .filePath)
        tokens += matches(using: codeRegex, in: text, kind: .codeSnippet)
        tokens += matches(using: numberRegex, in: text, kind: .number)
        tokens += matches(using: properNounRegex, in: text, kind: .properNounCandidate)

        // Keep deterministic order for testability and observability.
        return tokens.sorted {
            text.distance(from: text.startIndex, to: $0.range.lowerBound)
                < text.distance(from: text.startIndex, to: $1.range.lowerBound)
        }
    }

    private static func matches(using regex: NSRegularExpression, in text: String, kind: ProtectedToken.Kind) -> [ProtectedToken] {
        let nsRange = NSRange(text.startIndex..., in: text)

        return regex.matches(in: text, range: nsRange).compactMap { result in
            guard let range = Range(result.range, in: text) else { return nil }
            return ProtectedToken(kind: kind, value: String(text[range]), range: range)
        }
    }
}

enum GlossaryMatcher {
    static func match(glossary: [GlossaryEntry], in text: String) -> [GlossaryMatch] {
        guard !glossary.isEmpty else { return [] }

        var matches: [GlossaryMatch] = []
        for entry in glossary where !entry.source.isEmpty {
            let escaped = NSRegularExpression.escapedPattern(for: entry.source)
            let pattern = #"\b\#(escaped)\b"#
            let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            let nsRange = NSRange(text.startIndex..., in: text)
            regex?.matches(in: text, range: nsRange).forEach { result in
                guard let range = Range(result.range, in: text) else { return }
                matches.append(GlossaryMatch(source: entry.source, target: entry.target, range: range))
            }
        }

        return matches.sorted {
            text.distance(from: text.startIndex, to: $0.range.lowerBound)
                < text.distance(from: text.startIndex, to: $1.range.lowerBound)
        }
    }
}

enum AmbiguityHintDetector {
    static func detect(in text: String) -> [AmbiguityHint] {
        var hints: [AmbiguityHint] = []
        let lowered = text.lowercased()

        if lowered.contains(" it ") || lowered.hasPrefix("it ") || lowered.hasSuffix(" it") {
            hints.append(AmbiguityHint(category: "pronoun", message: "Pronoun 'it' may require explicit referent in target language."))
        }
        if lowered.contains("they") {
            hints.append(AmbiguityHint(category: "pronoun", message: "Pronoun 'they' can be singular or plural."))
        }
        if lowered.contains("you") {
            hints.append(AmbiguityHint(category: "register", message: "Pronoun 'you' can require politeness choice."))
        }

        return hints
    }
}

enum FormattingInspector {
    static func inspect(_ text: String) -> FormattingProfile {
        let leading = String(text.prefix { $0.isWhitespace })
        let trailing = String(text.reversed().prefix { $0.isWhitespace }.reversed())
        let newlineCount = text.reduce(into: 0) { partialResult, char in
            if char == "\n" {
                partialResult += 1
            }
        }

        return FormattingProfile(
            leadingWhitespace: leading,
            trailingWhitespace: trailing,
            newlineCount: newlineCount
        )
    }
}
