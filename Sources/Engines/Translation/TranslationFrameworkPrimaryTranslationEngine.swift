import Foundation

struct TranslationFrameworkPrimaryTranslationEngine: DiagnosticCapableTranslationEngine {
    fileprivate enum RecoveryFailureKind: String {
        case missingSourceLanguage = "missing_source_language"
        case missingTargetLanguage = "missing_target_language"
        case missingSourceAndTargetLanguage = "missing_source_and_target_language"
        case unsupportedLanguagePairing = "unsupported_language_pairing"
    }

    private actor RecoveryDiagnosticState {
        private(set) var failureKind: RecoveryFailureKind?

        func capture(message: String) {
            guard let parsed = TranslationFrameworkPrimaryTranslationEngine.parseRecoveryFailureKind(from: message) else { return }
            failureKind = parsed
        }
    }

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
            let recoveryDiagnosticState = RecoveryDiagnosticState()
            let translated = await recoveryEngine.recoverUnsafeTranslation(
                sourceText: segment.text,
                sourceLanguage: input.sourceLanguage,
                targetLanguage: input.targetLanguage,
                onDiagnosticEvent: { message in
                    Task { await recoveryDiagnosticState.capture(message: message) }
                    onDiagnosticEvent?(message)
                }
            )
            let recoveryFailureKind = await recoveryDiagnosticState.failureKind

            let normalized = translated?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !normalized.isEmpty else {
                throw TranslationFrameworkPrimaryEngineError.recoveryFailed(
                    segmentIndex: segment.index,
                    sourceLanguage: input.sourceLanguage,
                    targetLanguage: input.targetLanguage,
                    failureKind: recoveryFailureKind
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

    private static func parseRecoveryFailureKind(from message: String) -> RecoveryFailureKind? {
        let marker = "translation-framework-recovery:failure-kind="
        guard let range = message.range(of: marker) else { return nil }
        let raw = String(message[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return RecoveryFailureKind(rawValue: raw)
    }
}

private enum TranslationFrameworkPrimaryEngineError: LocalizedError {
    case recoveryFailed(
        segmentIndex: Int,
        sourceLanguage: String,
        targetLanguage: String,
        failureKind: TranslationFrameworkPrimaryTranslationEngine.RecoveryFailureKind?
    )

    var errorDescription: String? {
        switch self {
        case .recoveryFailed(let segmentIndex, let sourceLanguage, let targetLanguage, let failureKind):
            let reasonSuffix: String
            if let failureKind {
                reasonSuffix = " reason=\(failureKind.rawValue)."
            } else {
                reasonSuffix = "."
            }
            return "Translation Framework could not complete translation for segment=\(segmentIndex) (\(sourceLanguage)->\(targetLanguage))\(reasonSuffix) Please confirm language-pack download and retry."
        }
    }
}
