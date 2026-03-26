import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var pendingImportedText: String?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let window = UIWindow(windowScene: windowScene)
        let storyboard = UIStoryboard(name: "Main", bundle: nil)
        if let rootViewController = storyboard.instantiateInitialViewController() {
            window.rootViewController = rootViewController
        } else {
            let fallback = UIViewController()
            fallback.view.backgroundColor = .systemBackground
            let label = UILabel()
            label.text = "Failed to load Main.storyboard"
            label.textColor = .systemRed
            label.translatesAutoresizingMaskIntoConstraints = false
            fallback.view.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: fallback.view.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: fallback.view.centerYAnchor),
            ])
            window.rootViewController = fallback
        }
        self.window = window
        window.makeKeyAndVisible()
        importSharedTextIfNeeded()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        importSharedTextIfNeeded()
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let matchedURL = URLContexts.map(\.url).first(where: { $0.scheme == "prebabellens" }) else { return }
        if let directText = parseSharedText(from: matchedURL), !directText.isEmpty {
            pendingImportedText = directText
        }
        importSharedTextIfNeeded()
    }

    private func importSharedTextIfNeeded() {
        if let text = SharedImportStore.consumePendingText() {
            pendingImportedText = text
        }

        guard let text = pendingImportedText, !text.isEmpty else { return }
        guard let controller = translationViewController else { return }
        controller.applyImportedInput(text)
        pendingImportedText = nil
    }

    private var translationViewController: TranslationViewController? {
        if let navigationController = window?.rootViewController as? UINavigationController {
            return navigationController.viewControllers.first as? TranslationViewController
        }
        return window?.rootViewController as? TranslationViewController
    }

    private func parseSharedText(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let textItem = components.queryItems?.first(where: { $0.name == "text" }),
              let value = textItem.value
        else {
            return nil
        }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}
