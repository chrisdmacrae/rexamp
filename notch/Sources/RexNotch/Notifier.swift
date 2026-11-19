import UserNotifications

/// Posts macOS notifications when an agent finishes, fails, or needs you, with
/// Allow and Deny buttons on permission requests. Without permission to
/// notify, the notch peeks and shows the question itself instead.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private weak var model: NotchModel?
    private var center: UNUserNotificationCenter { .current() }

    func start(_ model: NotchModel) {
        self.model = model
        // Notifications need an app bundle; `swift run` has none and would crash.
        guard Bundle.main.bundleIdentifier != nil else { return }
        center.delegate = self
        let show = UNNotificationAction(identifier: "show", title: "Show")
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "agent", actions: [show], intentIdentifiers: []),
            UNNotificationCategory(identifier: "permission", actions: [
                UNNotificationAction(identifier: "allow", title: "Allow"),
                UNNotificationAction(identifier: "deny", title: "Deny", options: .destructive),
                show,
            ], intentIdentifiers: []),
        ])
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in model.notifies = granted }
        }
    }

    /// Posts a notification that replaces any earlier one with the same id,
    /// so each agent has at most one.
    func post(id: String, title: String, subtitle: String, body: String, urgent: Bool, permission: Bool = false, info: [String: String]) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.subtitle = subtitle
        c.body = body
        c.userInfo = info
        c.categoryIdentifier = permission ? "permission" : "agent"
        c.threadIdentifier = id
        if urgent { c.sound = .default }
        center.add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }

    func remove(id: String) {
        guard model?.notifies == true else { return }
        center.removeDeliveredNotifications(withIdentifiers: [id])
    }

    nonisolated func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse) async {
        let info = r.notification.request.content.userInfo as? [String: String] ?? [:]
        let action = r.actionIdentifier
        await MainActor.run { self.respond(action, info) }
    }

    private func respond(_ action: String, _ info: [String: String]) {
        guard let model else { return }
        if let id = info["desktop"], let s = model.desktop.first(where: { $0.id == id }) {
            model.open(s)
            return
        }
        guard let block = info["block"], let a = model.agents.first(where: { $0.block == block }) else { return }
        switch action {
        case "allow": model.choose(a, option: 0)
        case "deny": model.choose(a, option: max(0, (a.prompt?.options.count ?? 1) - 1))
        default:
            // A question is answered in the notch; anything else in its pane.
            if a.state == "blocked", a.prompt != nil { model.expanded = true } else { model.focus(a) }
        }
    }
}
