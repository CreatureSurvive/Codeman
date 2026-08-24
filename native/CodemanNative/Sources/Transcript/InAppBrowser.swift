import SafariServices
import SwiftUI

/// Opens web links from transcript text inside the app.
///
/// The default `openURL` hands the URL to Safari, which switches apps — a hard context break for
/// what is usually a glance at a doc page referenced mid-conversation, and it loses the reader's
/// place in a long transcript. `SFSafariViewController` keeps the session on screen behind a sheet
/// and still gives a real browser: reader mode, the address bar, and the user's own cookies.
///
/// ⚠️ Only `http`/`https` are intercepted. `mailto:`, `tel:` and custom schemes must reach the
/// system — Safari cannot open them, and swallowing them would make those links silently dead.
struct InAppBrowserModifier: ViewModifier {
    @State private var target: BrowsableURL?

    func body(content: Content) -> some View {
        content
            .environment(\.openURL, OpenURLAction { url in
                guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                    return .systemAction
                }
                target = BrowsableURL(url: url)
                return .handled
            })
            .sheet(item: $target) { item in
                SafariSheet(url: item.url).ignoresSafeArea()
            }
    }

    private struct BrowsableURL: Identifiable {
        let url: URL
        var id: String { url.absoluteString }
    }
}

extension View {
    /// Route web links in this subtree to an in-app browser sheet.
    ///
    /// ⚠️ Applies a `.sheet`, and SwiftUI honours only the FIRST sheet attached to a given view —
    /// so put this on a view that does not already present one.
    func inAppBrowser() -> some View {
        modifier(InAppBrowserModifier())
    }
}

/// `SFSafariViewController` as a SwiftUI sheet.
struct SafariSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        // Bar collapsing fights a sheet's own drag-to-dismiss, so the chrome stays put.
        let controller = SFSafariViewController(url: url, configuration: configuration)
        controller.dismissButtonStyle = .close
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
