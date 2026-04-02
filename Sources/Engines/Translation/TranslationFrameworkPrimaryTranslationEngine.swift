import Foundation

struct TranslationFrameworkPrimaryTranslationEngine: DiagnosticCapableTranslationEngine {
    private let recoveryEngine: UnsafeSegmentRecoveryEngine

    init(recoveryEngine: UnsafeSegmentRecoveryEngine) {
        self.recoveryEngine = recoveryEngine
    }

    var name: String { "translation-framework-primary" }

    func translate(_ input: TranslationInput) async throws -> [SegmentOutput] {
        try await translate(input, onPartialResult: nil, onDiagnosticEvent: nil)
    }

    func translate(
        _ input: TranslationInput,
        onPartialResult: (@Sendable (_ segmentIndex: Int, _ partialTranslation: String) -> Void)?
    ) async throws -> [SegmentOutput] {
        try await translate(input, onPartialResult: onPartialResult, onDiagnosticEvent: nil)
    }

    func translate(
        _ input: TranslationInput,
        onPartialResult: (@Sendable (_ segmentIndex: Int, _ partialTranslation: String) -> Void)?,
        onDiagnosticEvent: (@Sendable (_ message: String) -> Void)?
    ) async throws -> [SegmentOutput] {
        let segments = input.segments.isEmpty
            ? [TextSegment(index: 0, text: input.originalText, role: .leading)]
            : input.segments

        onDiagnosticEvent?("engine=tf-primary-start segments=\(segments.count) source=\(input.sourceLanguage) target=\(input.targetLanguage)")

        var outputs: [SegmentOutput] = []
        outputs.reserveCapacity(segments.count)

        for segment in segments {
            try Task.checkCancellation()
            let translated = await recoveryEngine.recoverUnsafeTranslation(
                sourceText: segment.text,
                sourceLanguage: input.sourceLanguage,
                targetLanguage: input.targetLanguage,
                onDiagnosticEvent: onDiagnosticEvent
            )

            let normalized = translated?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !normalized.isEmpty else {
                throw TranslationFrameworkPrimaryEngineError.recoveryFailed(
                    segmentIndex: segment.index,
                    sourceLanguage: input.sourceLanguage,
                    targetLanguage: input.targetLanguage
                )
            }

            onPartialResult?(segment.index, normalized)
            outputs.append(
                SegmentOutput(
                    segmentIndex: segment.index,
                    sourceText: segment.text,
                    translatedText: normalized,
                    isUnsafeFallback: false,
                    isUnsafeRecoveredByTranslationFramework: false
                )
            )
        }

        onDiagnosticEvent?("engine=tf-primary-finished segments=\(outputs.count)")
        return outputs
    }
}

private enum TranslationFrameworkPrimaryEngineError: LocalizedError {
    case recoveryFailed(segmentIndex: Int, sourceLanguage: String, targetLanguage: String)

    var errorDescription: String? {
        switch self {
        case .recoveryFailed(let segmentIndex, let sourceLanguage, let targetLanguage):
            return "Translation Framework could not complete translation for segment=\(segmentIndex) (\(sourceLanguage)->\(targetLanguage)). Please confirm language-pack download and retry."
        }
    }
}
