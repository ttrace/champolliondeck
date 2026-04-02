import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum IOSPreferredTranslationEngineMode: Sendable {
    case translationFramework
    case foundationModels
}

struct FixedTranslationEnginePolicy: TranslationEnginePolicy {
    private let engine: TranslationEngine

    init(engine: TranslationEngine) {
        self.engine = engine
    }

    func resolveEngine(for _: TranslationRequest) -> TranslationEngine {
        engine
    }
}

final class IOSAdaptiveTranslationEnginePolicy: TranslationEnginePolicy, @unchecked Sendable {
    private let translationFrameworkEngine: TranslationEngine
    private let hybridEngine: TranslationEngine
    private let lock = NSLock()
    private var preferredMode: IOSPreferredTranslationEngineMode = .translationFramework

    init(
        translationFrameworkEngine: TranslationEngine,
        hybridEngine: TranslationEngine
    ) {
        self.translationFrameworkEngine = translationFrameworkEngine
        self.hybridEngine = hybridEngine
    }

    func resolveEngine(for _: TranslationRequest) -> TranslationEngine {
        #if os(iOS)
        lock.lock()
        defer { lock.unlock() }
        if preferredMode == .foundationModels, isFoundationModelsReady {
            return hybridEngine
        }
        return translationFrameworkEngine
        #else
        return hybridEngine
        #endif
    }

    func setPreferredMode(_ mode: IOSPreferredTranslationEngineMode) {
        lock.lock()
        defer { lock.unlock() }
        switch mode {
        case .translationFramework:
            preferredMode = .translationFramework
        case .foundationModels:
            preferredMode = isFoundationModelsReady ? .foundationModels : .translationFramework
        }
    }

    func currentPreferredMode() -> IOSPreferredTranslationEngineMode {
        lock.lock()
        defer { lock.unlock() }
        if preferredMode == .foundationModels, isFoundationModelsReady {
            return .foundationModels
        }
        return .translationFramework
    }

    func isFoundationModelsAvailable() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isFoundationModelsReady
    }

    private var isFoundationModelsReady: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability {
                return true
            }
        }
        #endif
        return false
    }
}
