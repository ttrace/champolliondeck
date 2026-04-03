import Foundation
#if canImport(Logging)
import Logging
#endif

#if canImport(Translation)
@preconcurrency import Translation

@MainActor
final class TranslationFrameworkUnsafeRecoveryController: ObservableObject, UnsafeSegmentRecoveryEngine, @unchecked Sendable {
    private enum MissingLanguageKind: String {
        case source = "missing_source_language"
        case target = "missing_target_language"
        case sourceAndTarget = "missing_source_and_target_language"
        case unsupportedPair = "unsupported_language_pairing"
    }

    #if canImport(Logging)
    private static let logger = Logger(subsystem: "com.ttrace.prebabellens", category: "translation-framework")
    #endif
    private struct RecoveryChunk {
        enum Kind {
            case text
            case separator
        }

        let kind: Kind
        let value: String
    }

    struct PendingRequest {
        let id: UUID
        let sourceText: String
        let sourceLanguage: String
        let targetLanguage: String
        let onDiagnosticEvent: (@Sendable (_ message: String) -> Void)?
    }

    @Published private(set) var configuration: TranslationSession.Configuration?
    @Published private(set) var requestGeneration = UUID()

    private var pendingRequest: PendingRequest?
    private var pendingContinuation: CheckedContinuation<String?, Never>?

    private func log(_ message: String) {
    #if canImport(Logging)
        let context = "request=\(pendingRequest?.id.uuidString ?? "none")"
        TranslationFrameworkUnsafeRecoveryController.logger.debug("\(message, privacy: .public) [\(context)]")
    #else
        print("[TranslationFramework] \(message)")
    #endif
    }

    func recoverUnsafeTranslation(
        sourceText: String,
        sourceLanguage: String,
        targetLanguage: String,
        onDiagnosticEvent: (@Sendable (_ message: String) -> Void)?
    ) async -> String? {
        guard pendingRequest == nil else {
            onDiagnosticEvent?("translation-framework-recovery: skipped-because-request-is-already-active")
            return nil
        }

        pendingRequest = PendingRequest(
            id: UUID(),
            sourceText: sourceText,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            onDiagnosticEvent: onDiagnosticEvent
        )
        var configuration = TranslationSession.Configuration(
            source: localeLanguage(from: sourceLanguage),
            target: localeLanguage(from: targetLanguage)
        )
        configuration.invalidate()
        requestGeneration = UUID()
        self.configuration = configuration

        return await withCheckedContinuation { continuation in
            pendingContinuation = continuation
        }
    }

    func processPendingRequest(using session: TranslationSession) async {
        guard let request = pendingRequest else { return }

        log("request-started")
        do {
            let availability = LanguageAvailability()
            let status = try await availability.status(
                for: request.sourceText,
                to: localeLanguage(from: request.targetLanguage)
            )
            log("availability=\(describe(status))")

            if status == .unsupported {
                log("unsupported-language-pairing")
                if let missingLanguageKind = await diagnoseMissingLanguageKind(
                    sourceLanguage: request.sourceLanguage,
                    targetLanguage: request.targetLanguage,
                    using: availability
                ) {
                    request.onDiagnosticEvent?(
                        "translation-framework-recovery:failure-kind=\(missingLanguageKind.rawValue)"
                    )
                    log("failure-kind=\(missingLanguageKind.rawValue)")
                }
                finishPendingRequest(with: nil)
                return
            }

            if status == .supported {
                log("preparing-download-or-consent")
                try await session.prepareTranslation()
                log("prepare-finished")
            }

            let translated = try await translatePreservingSeparators(
                request.sourceText,
                using: session
            )
            log("request-finished chars=\(translated.count)")
            finishPendingRequest(with: translated.isEmpty ? nil : translated)
        } catch is CancellationError {
            log("cancelled")
            finishPendingRequest(with: nil)
        } catch {
            log("failed: \(error.localizedDescription)")
            finishPendingRequest(with: nil)
        }
    }

    private func finishPendingRequest(with translatedText: String?) {
        configuration = nil
        pendingRequest = nil
        pendingContinuation?.resume(returning: translatedText)
        pendingContinuation = nil
    }

    private func translatePreservingSeparators(
        _ text: String,
        using session: TranslationSession
    ) async throws -> String {
        let chunks = splitIntoRecoveryChunks(text)
        let textChunks = chunks.enumerated().compactMap { index, chunk -> TranslationSession.Request? in
            guard chunk.kind == .text else { return nil }
            return TranslationSession.Request(
                sourceText: chunk.value,
                clientIdentifier: String(index)
            )
        }

        guard !textChunks.isEmpty else { return text }
        nonisolated(unsafe) let detachedTextChunks = textChunks
        let responses = try await session.translations(from: detachedTextChunks)
        let translatedByIdentifier = Dictionary(
            uniqueKeysWithValues: responses.compactMap { response -> (String, String)? in
                guard let clientIdentifier = response.clientIdentifier else { return nil }
                return (clientIdentifier, response.targetText)
            }
        )

        return chunks.enumerated().map { index, chunk in
            switch chunk.kind {
            case .separator:
                return chunk.value
            case .text:
                return translatedByIdentifier[String(index)] ?? chunk.value
            }
        }
        .joined()
    }

    private func splitIntoRecoveryChunks(_ text: String) -> [RecoveryChunk] {
        guard !text.isEmpty else { return [] }

        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let regex = try? NSRegularExpression(pattern: #"\n+"#)
        let matches = regex?.matches(in: text, range: nsRange) ?? []
        guard !matches.isEmpty else {
            return [RecoveryChunk(kind: .text, value: text)]
        }

        var chunks: [RecoveryChunk] = []
        var cursor = text.startIndex

        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            if cursor < range.lowerBound {
                chunks.append(
                    RecoveryChunk(kind: .text, value: String(text[cursor..<range.lowerBound]))
                )
            }
            chunks.append(
                RecoveryChunk(kind: .separator, value: String(text[range]))
            )
            cursor = range.upperBound
        }

        if cursor < text.endIndex {
            chunks.append(
                RecoveryChunk(kind: .text, value: String(text[cursor..<text.endIndex]))
            )
        }

        return chunks
    }

    private func localeLanguage(from code: String) -> Locale.Language? {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "und" else { return nil }
        return Locale.Language(identifier: canonicalTranslationFrameworkLanguageIdentifier(from: trimmed))
    }

    private func canonicalTranslationFrameworkLanguageIdentifier(from rawCode: String) -> String {
        let normalized = rawCode
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()

        // Translation.framework can treat generic "en" as unavailable even when
        // regional English assets (en-US / en-GB) are present.
        if normalized == "en" {
            return "en-US"
        }

        if normalized == "zh" || normalized == "zh-cn" || normalized == "zh-sg" {
            return "zh-Hans"
        }

        if normalized == "zh-tw" || normalized == "zh-hk" || normalized == "zh-mo" {
            return "zh-Hant"
        }

        return rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func describe(_ status: LanguageAvailability.Status) -> String {
        switch status {
        case .installed:
            return "installed"
        case .supported:
            return "supported"
        case .unsupported:
            return "unsupported"
        @unknown default:
            return "unknown"
        }
    }

    private func diagnoseMissingLanguageKind(
        sourceLanguage: String,
        targetLanguage: String,
        using availability: LanguageAvailability
    ) async -> MissingLanguageKind? {
        guard let source = localeLanguage(from: sourceLanguage),
              let target = localeLanguage(from: targetLanguage) else {
            return nil
        }

        let sourceStatus = await availability.status(from: source, to: nil)
        let targetStatus = await availability.status(from: target, to: nil)

        let sourceMissing = sourceStatus != .installed
        let targetMissing = targetStatus != .installed

        if sourceMissing && targetMissing {
            return .sourceAndTarget
        }
        if sourceMissing {
            return .source
        }
        if targetMissing {
            return .target
        }
        return .unsupportedPair
    }
}
#endif
