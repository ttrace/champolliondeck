import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

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
    }
}
