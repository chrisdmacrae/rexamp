import UserNotifications

/// Posts macOS notifications when an agent finishes, fails, or needs you, with
/// Allow and Deny buttons on permission requests. Notch previews are independent.
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
        let reply = UNTextInputNotificationAction(identifier: "reply", title: "Reply", options: [],
                                                  textInputButtonTitle: "Send", textInputPlaceholder: "Reply")
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "agent", actions: [show], intentIdentifiers: []),
            UNNotificationCategory(identifier: "reply", actions: [reply, show], intentIdentifiers: []),
            UNNotificationCategory(identifier: "permission", actions: [
                UNNotificationAction(identifier: "allow", title: "Allow"),
                UNNotificationAction(identifier: "deny", title: "Deny", options: .destructive),
                show,
            ], intentIdentifiers: []),
        ])
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in self.refreshAuthorization() }
        }
    }

    func refreshAuthorization() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        center.getNotificationSettings { settings in
            Task { @MainActor in
                self.model?.notifies = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
                self.model?.notificationPermission = switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral: "Allowed"
                case .denied: "Not allowed"
                case .notDetermined: "Not requested"
                @unknown default: "Unknown"
                }
            }
        }
    }

    func test(completion: @escaping (String?) -> Void) {
        guard Bundle.main.bundleIdentifier != nil else { completion("Notifications require the built app bundle."); return }
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            Task { @MainActor in
                self.refreshAuthorization()
                guard granted else { completion(error?.localizedDescription ?? "Allow RexNotch notifications in macOS Notification Settings first."); return }
                let content = UNMutableNotificationContent()
                content.title = "RexNotch test notification"
                content.body = "You’re ready to receive agent activity notifications."
                if self.model?.settings.values.notificationSound == true { content.sound = .default }
                do {
                    try await self.center.add(UNNotificationRequest(identifier: "rexnotch-test", content: content, trigger: nil))
                    completion(nil)
                } catch { completion(error.localizedDescription) }
            }
        }
    }

    /// Posts a notification that replaces any earlier one with the same id,
    /// so each agent has at most one.
    func post(id: String, title: String, subtitle: String, body: String, urgent: Bool, permission: Bool = false, reply: Bool = false, info: [String: String]) {
        let c = UNMutableNotificationContent()
        c.title = title
        let preferences = model?.settings.values ?? Preferences()
        c.subtitle = preferences.notificationText ? subtitle : ""
        c.body = preferences.notificationText ? body : (urgent ? "An agent needs your attention." : "An agent finished its task.")
        c.userInfo = info
        c.categoryIdentifier = permission ? "permission" : reply ? "reply" : "agent"
        c.threadIdentifier = id
        if urgent && preferences.notificationSound { c.sound = .default }
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
        let text = (r as? UNTextInputNotificationResponse)?.userText
        await MainActor.run { self.respond(action, info, text) }
    }

    private func respond(_ action: String, _ info: [String: String], _ text: String?) {
        guard let model else { return }
        if let id = info["desktop"], let s = model.visibleDesktop.first(where: { $0.id == id }) {
            model.open(s)
            return
        }
        guard let block = info["block"], let a = model.visibleAgents.first(where: { $0.block == block }) else { return }
        switch action {
        case "allow": model.choose(a, option: 0)
        case "deny": model.choose(a, option: max(0, (a.prompt?.options.count ?? 1) - 1))
        case "reply":
            if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { model.reply(a, text: text) }
        default:
            // Whatever an agent asks is answered in the notch; anything else in its pane.
            if a.shownState == "blocked" { model.expanded = true } else { model.focus(a) }
        }
    }
}
