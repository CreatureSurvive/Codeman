import Foundation
import UserNotifications

/// Local notifications for agent state changes.
///
/// Web Push is a browser capability, so the native app cannot reuse the server's push
/// subscription path. Instead it raises **local** notifications from the SSE hook events it is
/// already receiving, which covers the case that matters: the app is in the foreground or
/// recently backgrounded and an agent starts waiting on a human.
///
/// This deliberately does not promise delivery while the app is suspended — that would need a
/// real APNs pipeline, and claiming it without one would be a lie the user only discovers when
/// they miss a prompt. `Troubleshooting.md` states the limit plainly.
final class NotificationPresenter: @unchecked Sendable {
    static let shared = NotificationPresenter()

    private let center = UNUserNotificationCenter.current()
    private let lock = NSLock()
    private var enabled = false
    /// Suppresses a repeat notification for the same session inside this window.
    private var lastNotified: [String: Date] = [:]
    private static let coalesceWindow: TimeInterval = 30

    private init() {}

    func setEnabled(_ value: Bool) {
        lock.lock()
        enabled = value
        lock.unlock()
    }

    func requestAuthorizationIfNeeded() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            setEnabled(true)
            return true
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            setEnabled(granted)
            return granted
        default:
            setEnabled(false)
            return false
        }
    }

    func notifyNeedsAttention(sessionName: String) {
        post(
            key: "needs:\(sessionName)",
            title: sessionName,
            body: "Waiting for your decision.",
            interruption: .timeSensitive
        )
    }

    func notifyIdle(sessionName: String) {
        post(
            key: "idle:\(sessionName)",
            title: sessionName,
            body: "Finished — ready for your next prompt.",
            interruption: .active
        )
    }

    private func post(key: String, title: String, body: String, interruption: UNNotificationInterruptionLevel) {
        lock.lock()
        let isEnabled = enabled
        let last = lastNotified[key]
        if isEnabled { lastNotified[key] = .now }
        lock.unlock()

        guard isEnabled else { return }
        if let last, Date.now.timeIntervalSince(last) < Self.coalesceWindow { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = interruption

        let request = UNNotificationRequest(identifier: key + "-\(Int(Date.now.timeIntervalSince1970))",
                                            content: content,
                                            trigger: nil)
        center.add(request) { error in
            if let error {
                Log.ui.warning("Notification failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
