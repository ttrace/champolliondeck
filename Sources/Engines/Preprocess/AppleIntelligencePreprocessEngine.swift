import Foundation
import NaturalLanguage
#if canImport(FoundationModels)
import FoundationModels
#endif

struct AppleIntelligencePreprocessEngine: PreprocessEngine {
    let name: String = "apple-intelligence-preprocess-v1"

    func analyze(_ request: TranslationRequest) -> (input: TranslationInput, traces: [PreprocessTrace]) {
        let startedAt = Date()
        let detection = HeuristicLanguageDetector.detectLanguage(text: request.text)
        let input = TranslationInput(
            sourceLanguage: detection.detectedLanguageCode,
            targetLanguage: request.targetLanguage,
            originalText: request.text,
            detectedLanguageCode: detection.detectedLanguageCode,
            isDetectedLanguageSupportedByAppleIntelligence: detection.isSupportedByAppleIntelligence,
            segments: [],
            segmentJoinersAfter: [],
            protectedTokens: [],
            glossaryMatches: [],
            ambiguityHints: [],
            formatting: FormattingProfile(
                leadingWhitespace: "",
                trailingWhitespace: "",
                newlineCount: 0
            )
        )

        var traces = [
            PreprocessTrace(
                step: "ai-heuristic-language-detection",
                summary: "detected=\(detection.detectedLanguageCode), ai_supported=\(detection.isSupportedByAppleIntelligence), method=\(detection.method)"
            )
        ]

        let elapsedMs = Date().timeIntervalSince(startedAt) * 1000
        traces.append(
            PreprocessTrace(
                step: "ai-heuristic-processing-time",
                summary: String(format: "%.2f ms", elapsedMs)
            )
        )

        return (input: input, traces: traces)
    }
}

struct CompositePreprocessEngine: PreprocessEngine {
    let deterministicEngine: PreprocessEngine
    let appleIntelligenceEngine: PreprocessEngine

    var name: String {
        "\(deterministicEngine.name)+\(appleIntelligenceEngine.name)"
    }

    func analyze(_ request: TranslationRequest) -> (input: TranslationInput, traces: [PreprocessTrace]) {
        let deterministic = deterministicEngine.analyze(request)
        let ai = appleIntelligenceEngine.analyze(request)
        var mergedInput = deterministic.input
        var traces = deterministic.traces + ai.traces

        let deterministicCode = mergedInput.detectedLanguageCode ?? "und"
        let aiCode = ai.input.detectedLanguageCode ?? "und"
        let shouldPromoteAIResult = (deterministicCode == "und" || !mergedInput.isDetectedLanguageSupportedByAppleIntelligence)
            && aiCode != "und"
            && ai.input.isDetectedLanguageSupportedByAppleIntelligence

        if shouldPromoteAIResult {
            mergedInput.sourceLanguage = aiCode
            mergedInput.detectedLanguageCode = aiCode
            mergedInput.isDetectedLanguageSupportedByAppleIntelligence = true
            traces.append(
                PreprocessTrace(
                    step: "ai-heuristic-language-merge",
                    summary: "promoted detected language from \(deterministicCode) to \(aiCode)"
                )
            )
        } else {
            traces.append(
                PreprocessTrace(
                    step: "ai-heuristic-language-merge",
                    summary: "kept deterministic detected language \(deterministicCode)"
                )
            )
        }

        if request.experimentMode.usesSegmentation, !mergedInput.segments.isEmpty {
            let refinedSegmentation = AppleIntelligenceContextSegmenter.refine(
                segments: mergedInput.segments,
                joinersAfter: mergedInput.segmentJoinersAfter
            )
            let beforeCount = mergedInput.segments.count
            mergedInput.segments = refinedSegmentation.segments
            mergedInput.segmentJoinersAfter = refinedSegmentation.joinersAfter
            traces.append(
                PreprocessTrace(
                    step: "ai-heuristic-context-front-stage",
                    summary: "context-boundary-splits=\(refinedSegmentation.diagnostics.frontBoundarySplitCount), chunks=\(refinedSegmentation.diagnostics.frontChunkCount)"
                )
            )
            traces.append(
                PreprocessTrace(
                    step: "ai-heuristic-context-back-stage",
                    summary: "intra-chunk-merges=\(refinedSegmentation.diagnostics.backMergeCount), output-segments=\(refinedSegmentation.segments.count)"
                )
            )
            traces.append(
                PreprocessTrace(
                    step: "ai-heuristic-context-segmentation",
                    summary: "segments \(beforeCount) -> \(mergedInput.segments.count), method=ai-context-front+back"
                )
            )
        }

        return (
            input: mergedInput,
            traces: traces
        )
    }
}

private enum AppleIntelligenceContextSegmenter {
    private static let preferredMinimumChars = 180
    private static let preferredMaximumChars = 420
    private static let hardMaximumChars = 520

    static func refine(segments: [TextSegment], joinersAfter: [String]) -> HeuristicSegmentationResult {
        guard !segments.isEmpty else {
            return HeuristicSegmentationResult(
                segments: [],
                joinersAfter: [],
                diagnostics: ContextSegmentationDiagnostics(
                    frontBoundarySplitCount: 0,
                    frontChunkCount: 0,
                    backMergeCount: 0
                )
            )
        }

        var refinedTexts: [String] = []
        var refinedJoiners: [String] = []
        var frontBoundarySplits = 0
        var frontChunkCount = 0
        var backMergeCount = 0

        for (index, segment) in segments.enumerated() {
            let outerJoiner = joinersAfter.indices.contains(index) ? joinersAfter[index] : ""
            let units = sentenceUnits(in: segment.text, finalJoiner: outerJoiner)
            guard !units.isEmpty else { continue }

            let frontChunks = splitByContextBoundary(units)
            frontChunkCount += frontChunks.count
            frontBoundarySplits += max(0, frontChunks.count - 1)

            for chunk in frontChunks where !chunk.isEmpty {
                if chunk.count == 1 {
                    refinedTexts.append(chunk[0].text)
                    refinedJoiners.append(chunk[0].joinerAfter)
                    continue
                }

                var currentText = chunk[0].text
                for unitIndex in 1..<chunk.count {
                    let bridge = chunk[unitIndex - 1].joinerAfter
                    let candidate = currentText + bridge + chunk[unitIndex].text
                    if shouldMergeCandidate(current: currentText, candidate: candidate) {
                        currentText = candidate
                        backMergeCount += 1
                    } else {
                        refinedTexts.append(currentText)
                        refinedJoiners.append(chunk[unitIndex - 1].joinerAfter)
                        currentText = chunk[unitIndex].text
                    }
                }

                if let last = chunk.last {
                    refinedTexts.append(currentText)
                    refinedJoiners.append(last.joinerAfter)
                }
            }
        }

        if refinedTexts.isEmpty {
            return HeuristicSegmentationResult(
                segments: segments,
                joinersAfter: joinersAfter,
                diagnostics: ContextSegmentationDiagnostics(
                    frontBoundarySplitCount: frontBoundarySplits,
                    frontChunkCount: frontChunkCount,
                    backMergeCount: backMergeCount
                )
            )
        }

        let indexedSegments = refinedTexts.enumerated().map { idx, text in
            TextSegment(index: idx, text: text)
        }
        return HeuristicSegmentationResult(
            segments: indexedSegments,
            joinersAfter: refinedJoiners,
            diagnostics: ContextSegmentationDiagnostics(
                frontBoundarySplitCount: frontBoundarySplits,
                frontChunkCount: frontChunkCount,
                backMergeCount: backMergeCount
            )
        )
    }

    // Stage 1: split clearly unrelated contexts before size optimization.
    private static func splitByContextBoundary(_ units: [SentenceUnit]) -> [[SentenceUnit]] {
        guard !units.isEmpty else { return [] }
        var chunks: [[SentenceUnit]] = [[units[0]]]

        for index in 1..<units.count {
            guard let previous = chunks[chunks.count - 1].last else {
                chunks.append([units[index]])
                continue
            }
            let current = units[index]

            if shouldStartNewContext(previous: previous.text, current: current.text) {
                chunks.append([current])
            } else {
                chunks[chunks.count - 1].append(current)
            }
        }

        return chunks
    }

    private static func shouldStartNewContext(previous: String, current: String) -> Bool {
        let prev = previous.trimmingCharacters(in: .whitespacesAndNewlines)
        let curr = current.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prev.isEmpty, !curr.isEmpty else { return false }

        if curr.hasPrefix("- ") || curr.hasPrefix("— ") || curr.hasPrefix("• ") || curr.hasPrefix("* ") {
            return true
        }

        let prevTokens = topicalTokens(from: prev)
        let currTokens = topicalTokens(from: curr)
        guard !prevTokens.isEmpty, !currTokens.isEmpty else { return false }

        let overlap = prevTokens.intersection(currTokens).count
        let minSize = min(prevTokens.count, currTokens.count)
        let overlapRatio = minSize > 0 ? Double(overlap) / Double(minSize) : 0

        return prev.count >= 120 && curr.count >= 120 && overlapRatio < 0.08
    }

    private static func topicalTokens(from text: String) -> Set<String> {
        let stopWords: Set<String> = [
            "the", "a", "an", "and", "or", "but", "to", "of", "in", "on", "for", "with",
            "is", "are", "was", "were", "be", "been", "it", "this", "that", "as", "at",
            "by", "from", "you", "we", "they", "he", "she", "i"
        ]

        return Set(
            text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 3 && !stopWords.contains($0) }
        )
    }

    private static func shouldMergeCandidate(current: String, candidate: String) -> Bool {
        let currentLength = current.count
        let candidateLength = candidate.count

        if currentLength < preferredMinimumChars {
            return candidateLength <= hardMaximumChars
        }

        if candidateLength > hardMaximumChars {
            return false
        }

        if currentLength >= preferredMinimumChars && candidateLength > preferredMaximumChars {
            return false
        }

        return true
    }

    private static func sentenceUnits(in text: String, finalJoiner: String) -> [SentenceUnit] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text

        var ranges: [Range<String.Index>] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            ranges.append(range)
            return true
        }

        if ranges.isEmpty {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [SentenceUnit(text: trimmed, joinerAfter: finalJoiner)]
        }

        var units: [SentenceUnit] = []
        for i in ranges.indices {
            let sentence = String(text[ranges[i]]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sentence.isEmpty else { continue }

            let joiner: String
            if i + 1 < ranges.count {
                joiner = String(text[ranges[i].upperBound..<ranges[i + 1].lowerBound])
            } else {
                joiner = finalJoiner
            }
            units.append(SentenceUnit(text: sentence, joinerAfter: joiner))
        }
        return units
    }
}

private struct SentenceUnit {
    let text: String
    let joinerAfter: String
}

private struct HeuristicSegmentationResult {
    let segments: [TextSegment]
    let joinersAfter: [String]
    let diagnostics: ContextSegmentationDiagnostics
}

private struct ContextSegmentationDiagnostics {
    let frontBoundarySplitCount: Int
    let frontChunkCount: Int
    let backMergeCount: Int
}

private struct HeuristicLanguageDetectionResult {
    let detectedLanguageCode: String
    let isSupportedByAppleIntelligence: Bool
    let method: String
}

private enum HeuristicLanguageDetector {
    private static let englishSignalWords: Set<String> = [
        "the", "and", "you", "for", "with", "from", "this", "that", "was", "were",
        "have", "has", "thank", "thanks", "again", "great", "impressed", "opportunity"
    ]

    static func detectLanguage(text: String) -> HeuristicLanguageDetectionResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return HeuristicLanguageDetectionResult(
                detectedLanguageCode: "und",
                isSupportedByAppleIntelligence: false,
                method: "ai-heuristic-empty-input"
            )
        }

        let supportedCodes = Set(AppleIntelligenceLanguageCatalog.supportedLanguageOptions().map(\.code))
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)

        let dominant = normalizeLanguageCode(recognizer.dominantLanguage?.rawValue ?? "und")
        let hypotheses = recognizer.languageHypotheses(withMaximum: 5)
            .map { (normalizeLanguageCode($0.key.rawValue), $0.value) }
            .sorted { $0.1 > $1.1 }

        if let supportedCandidate = hypotheses.first(where: { supportedCodes.contains($0.0) }) {
            if supportedCandidate.1 >= 0.25 {
                return HeuristicLanguageDetectionResult(
                    detectedLanguageCode: supportedCandidate.0,
                    isSupportedByAppleIntelligence: true,
                    method: "ai-heuristic-supported-hypothesis"
                )
            }
        }

        let englishWordCount = englishSignalCount(in: trimmed)
        let asciiLetterRatio = asciiLetterRatio(in: trimmed)
        if englishWordCount >= 3 && asciiLetterRatio >= 0.65 {
            return HeuristicLanguageDetectionResult(
                detectedLanguageCode: "en",
                isSupportedByAppleIntelligence: supportedCodes.contains("en"),
                method: "ai-heuristic-english-cue"
            )
        }

        if supportedCodes.contains(dominant) {
            return HeuristicLanguageDetectionResult(
                detectedLanguageCode: dominant,
                isSupportedByAppleIntelligence: true,
                method: "ai-heuristic-dominant-supported"
            )
        }

        return HeuristicLanguageDetectionResult(
            detectedLanguageCode: dominant,
            isSupportedByAppleIntelligence: false,
            method: "ai-heuristic-unsupported"
        )
    }

    private static func normalizeLanguageCode(_ raw: String) -> String {
        raw
            .lowercased()
            .split(separator: "-")
            .first
            .map(String.init) ?? raw.lowercased()
    }

    private static func englishSignalCount(in text: String) -> Int {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
            .reduce(into: 0) { count, token in
                if englishSignalWords.contains(token) {
                    count += 1
                }
            }
    }

    private static func asciiLetterRatio(in text: String) -> Double {
        var asciiLetters = 0
        var allLetters = 0

        for scalar in text.unicodeScalars {
            if CharacterSet.letters.contains(scalar) {
                allLetters += 1
                if scalar.isASCII {
                    asciiLetters += 1
                }
            }
        }

        guard allLetters > 0 else { return 0 }
        return Double(asciiLetters) / Double(allLetters)
    }
}
