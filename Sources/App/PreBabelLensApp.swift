import SwiftUI
#if os(macOS)
import AppKit
#endif

@main
struct PreBabelLens: App {
    private let viewModel: TranslationViewModel

    init() {
        let preprocess = DeterministicPreprocessEngine()
        let translationEngine = FoundationModelsTranslationEngine()
        let policy = FixedTranslationEnginePolicy(engine: translationEngine)
        let launchInputText = Self.launchInputText()

        self.viewModel = TranslationViewModel(
            orchestrator: TranslationOrchestrator(
                preprocessEngine: preprocess,
                enginePolicy: policy
            ),
            launchInputText: launchInputText
        )
    }

    var body: some Scene {
        mainScene
            .commands {
                CommandGroup(replacing: .newItem) { }
            }
    }

    @SceneBuilder
    private var mainScene: some Scene {
#if os(macOS)
        // URLスキーム起動時でも既存ウインドウを再利用し、状態を維持する。
        Window("Pre-Babel Lens", id: "main-window") {
            translationRootView
        }
#else
        WindowGroup("Pre-Babel Lens", id: "main-window") {
            translationRootView
        }
#endif
    }

    private var translationRootView: some View {
        TranslationView(viewModel: viewModel)
            .onOpenURL { url in
                Task { @MainActor in
                    await viewModel.handleIncomingURL(url)
                    #if os(macOS)
                    Self.activateExistingWindow()
                    #endif
                }
            }
    }

    private static func launchInputText() -> String? {
        let args = Array(ProcessInfo.processInfo.arguments.dropFirst())
        guard !args.isEmpty else { return nil }

        let combined = args.joined(separator: " ")
        let trimmed = combined.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

#if os(macOS)
    @MainActor
    private static func activateExistingWindow() {
        NSApp.activate(ignoringOtherApps: true)

        if let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first {
            window.makeKeyAndOrderFront(nil)
        }
    }
#endif
}
