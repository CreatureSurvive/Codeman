import UIKit
import Capacitor

private let codemanBackgroundColor = UIColor(red: 0x0b / 255.0, green: 0x0f / 255.0, blue: 0x17 / 255.0, alpha: 1)
private let codemanTopGradientColor = UIColor(red: 0x10 / 255.0, green: 0x2b / 255.0, blue: 0x38 / 255.0, alpha: 1)

class CodemanBridgeViewController: CAPBridgeViewController {
    private let backgroundGradient = CAGradientLayer()

    override func viewDidLoad() {
        super.viewDidLoad()
        installCodemanGradient()
        applyCodemanBackground()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        backgroundGradient.frame = view.bounds
        applyCodemanBackground()
    }

    private func installCodemanGradient() {
        backgroundGradient.colors = [
            codemanTopGradientColor.cgColor,
            UIColor(red: 0x0d / 255.0, green: 0x1b / 255.0, blue: 0x25 / 255.0, alpha: 1).cgColor,
            codemanBackgroundColor.cgColor,
        ]
        backgroundGradient.locations = [0, 0.35, 1]
        backgroundGradient.startPoint = CGPoint(x: 0.08, y: 0)
        backgroundGradient.endPoint = CGPoint(x: 1, y: 1)
        backgroundGradient.frame = view.bounds
        if backgroundGradient.superlayer == nil {
            view.layer.insertSublayer(backgroundGradient, at: 0)
        }
    }

    private func applyCodemanBackground() {
        view.backgroundColor = codemanTopGradientColor
        webView?.isOpaque = false
        webView?.backgroundColor = .clear
        webView?.scrollView.backgroundColor = .clear
        webView?.scrollView.contentInsetAdjustmentBehavior = .never
    }
}

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        window = UIWindow(windowScene: windowScene)
        window?.backgroundColor = codemanBackgroundColor
        window?.rootViewController = CodemanBridgeViewController()
        window?.makeKeyAndVisible()

        SceneDelegateProxy.shared.scene(scene, willConnectTo: session, options: connectionOptions)
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        SceneDelegateProxy.shared.scene(scene, openURLContexts: URLContexts)
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        SceneDelegateProxy.shared.scene(scene, continue: userActivity)
    }
}
