import AppKit
import Combine
import ServiceManagement
import SwiftUI

struct Preferences: Codable, Equatable {
    var display = "automatic"
    var showWhenIdle = false
    var showQuestions = true
    var showPreviews = true
    var notifyInput = true
    var notifyFailure = true
    var notifyCompletion = true
    var notificationSound = true
    var notificationText = true
    var showRex = true
    var showRemote = true
    var showClaude = true
    var showChatGPT = true
    var showUsage = true
    var automaticUpdates = true

    func notifies(state: String) -> Bool {
        switch state {
        case "blocked": notifyInput
        case "error": notifyFailure
        case "done": notifyCompletion
        default: false
        }
    }

    func showsDesktop(app: String) -> Bool {
        switch app {
        case "claude": showClaude
        case "chatgpt": showChatGPT
        default: false
        }
    }
}

@MainActor
final class Settings: ObservableObject {
    @Published var values: Preferences {
        didSet {
            if let data = try? JSONEncoder().encode(values) { defaults.set(data, forKey: "preferences") }
        }
    }
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        values = defaults.data(forKey: "preferences").flatMap { try? JSONDecoder().decode(Preferences.self, from: $0) } ?? Preferences()
    }
}

enum SettingsPage: String, CaseIterable {
    case general = "General", notifications = "Notifications", sources = "Sources", updates = "Updates", about = "About"

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .notifications: "bell.badge"
        case .sources: "square.grid.2x2"
        case .updates: "arrow.triangle.2.circlepath"
        case .about: "info.circle"
        }
    }
}

/// A normal, activating window; the floating notch remains a nonactivating panel.
@MainActor
final class SettingsWindowController: NSWindowController, NSToolbarDelegate {
    private let model: NotchModel

    init(model: NotchModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 510),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "RexNotch Settings"
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .preference
        super.init(window: window)
        let toolbar = NSToolbar(identifier: "Settings")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        toolbar.selectedItemIdentifier = NSToolbarItem.Identifier(SettingsPage.general.rawValue)
        showPage(.general)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func open() {
        model.expanded = false
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsPage.allCases.map { NSToolbarItem.Identifier($0.rawValue) }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let page = SettingsPage(rawValue: id.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = page.rawValue
        item.image = NSImage(systemSymbolName: page.symbol, accessibilityDescription: page.rawValue)
        item.target = self
        item.action = #selector(selectPage(_:))
        return item
    }

    @objc private func selectPage(_ sender: NSToolbarItem) {
        guard let page = SettingsPage(rawValue: sender.itemIdentifier.rawValue) else { return }
        showPage(page)
    }

    private func showPage(_ page: SettingsPage) {
        window?.contentView = NSHostingView(rootView: SettingsView(page: page)
            .environmentObject(model.settings).environmentObject(model))
    }
}

@MainActor
struct SettingsView: View {
    let page: SettingsPage
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var model: NotchModel
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var message: String?
    @State private var screens = NSScreen.screens

    var body: some View {
        Group {
            switch page {
            case .general: general
            case .notifications: notifications
            case .sources: sources
            case .updates: updates
            case .about: about
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginStatus = SMAppService.mainApp.status
            model.refreshNotificationAuthorization()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screens = NSScreen.screens
        }
        .onAppear { model.refreshNotificationAuthorization() }
        .alert("RexNotch", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: { Text(message ?? "") }
    }

    var general: some View {
        Form {
            Section("Startup") {
                Toggle(isOn: Binding(get: { loginStatus == .enabled }, set: { setLogin($0) })) {
                    label("Open at login", "Start RexNotch when you log in to your Mac.")
                }
                if loginStatus == .requiresApproval {
                    Button("Approve in Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                }
            }
            Section {
                Picker("Show on display", selection: $settings.values.display) {
                    Text("Automatic · Prefer built-in notch").tag("automatic")
                    ForEach(screens, id: \.displayID) { screen in
                        Text(screen.localizedName).tag(screen.displayID)
                    }
                    if settings.values.display != "automatic", !screens.contains(where: { $0.displayID == settings.values.display }) {
                        Text("Disconnected display (using automatic)").tag(settings.values.display)
                    }
                }
                Toggle(isOn: $settings.values.showWhenIdle) {
                    label("Show when idle", "Keep the dinosaur visible when no agents are running.")
                }
                Toggle(isOn: $settings.values.showQuestions) {
                    label("Automatically show questions", "Expand the notch when an agent needs your input.")
                }
            } header: { Text("Notch") } footer: {
                Text("Waiting agents always appear in the notch badge, even when automatic questions are off.")
            }
            Section {
                Toggle(isOn: $settings.values.showPreviews) {
                    label("Show activity previews", "Briefly expand the notch when an agent finishes or fails.")
                }
            } header: { Text("Previews") } footer: {
                Text("Previews work independently of macOS notifications. Appearance and motion follow your Mac’s accessibility settings.")
            }
        }.formStyle(.grouped).toggleStyle(.switch)
    }

    var updates: some View {
        Form {
            Section {
                Toggle(isOn: $settings.values.automaticUpdates) {
                    label("Automatically download and install updates", "Check GitHub Releases at startup and every hour. RexNotch restarts after updating.")
                }
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.updater.status).font(.caption).textSelection(.enabled)
                        if let date = model.updater.lastChecked {
                            Text("Last checked: \(date.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Check Now") { model.updater.check() }.disabled(model.updater.active)
                }
            } header: { Text("Updates") } footer: {
                Text("Updates include the bundled CLI. The separately installed terminal CLI is unchanged. Release downloads are verified against their SHA-256 checksums and checked for a valid app signature before installation.")
            }
        }.formStyle(.grouped).toggleStyle(.switch)
    }

    var notifications: some View {
        Form {
            Section("Notify me when") {
                Toggle("An agent needs input", isOn: $settings.values.notifyInput)
                Toggle("An agent fails", isOn: $settings.values.notifyFailure)
                Toggle("An agent finishes", isOn: $settings.values.notifyCompletion)
            }
            Section("Sound & privacy") {
                Toggle("Play sounds for attention-needed events", isOn: $settings.values.notificationSound)
                Toggle("Include task and question text", isOn: $settings.values.notificationText)
            }
            Section {
                HStack(alignment: .top, spacing: 12) {
                    DinoIcon(color: Palette.blocked).padding(7).background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("REXNOTCH · PREVIEW").font(.caption2).foregroundStyle(.secondary)
                        Text("Claude Code needs you").fontWeight(.semibold)
                        Text(settings.values.notificationText ? "Allow running the test suite?" : "An agent is waiting for your input.")
                    }
                }.padding(.vertical, 4)
                LabeledContent("macOS permission", value: model.notificationPermission)
                HStack {
                    Button("Open macOS Notification Settings…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                    }
                    Spacer()
                    Button("Send Test Notification") {
                        model.testNotification { message = $0 }
                    }
                }
            }
        }.formStyle(.grouped).toggleStyle(.switch)
    }

    var sources: some View {
        Form {
            Section {
                source("Rex agents", symbol: "terminal", enabled: $settings.values.showRex,
                       status: sourceStatus(error: "rex", count: model.agents.count))
                source("Remote Amp threads", symbol: "cloud", enabled: $settings.values.showRemote,
                       status: sourceStatus(error: "bridge", count: model.remote.count))
                source("Claude desktop sessions", symbol: "desktopcomputer", enabled: $settings.values.showClaude,
                       status: desktopStatus(app: "claude", bundle: "com.anthropic.claudefordesktop"))
                source("ChatGPT desktop sessions", symbol: "desktopcomputer", enabled: $settings.values.showChatGPT,
                       status: desktopStatus(app: "chatgpt", bundle: "com.openai.codex"))
            } header: { Text("Agents & sessions") } footer: {
                Text("Choose what appears in the notch and sends alerts. Hiding a source does not stop its agents or data collection.")
            }
            Section("Usage") {
                Toggle(isOn: $settings.values.showUsage) {
                    label("Show usage and subscription limits", "Amp credits and Claude / Codex subscription usage.")
                }
            }
        }.formStyle(.grouped).toggleStyle(.switch)
    }

    var about: some View {
        VStack(spacing: 13) {
            DinoIcon(color: .green).scaleEffect(2.5).frame(width: 80, height: 80)
                .background(Color.black, in: RoundedRectangle(cornerRadius: 18))
            Text("RexNotch").font(.title.bold())
            Text("Your coding agents, at a glance.").foregroundStyle(.secondary)
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development")")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("View on GitHub ↗") { NSWorkspace.shared.open(URL(string: "https://github.com/chrisdmacrae/rexnotch")!) }
                Button("Copy Diagnostics") {
                    let text = """
                    RexNotch \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development")
                    macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
                    HUD executable available: \(Bridge.executable() != nil)
                    Snapshot received: \(model.loaded)
                    Agents: \(model.agents.count), remote: \(model.remote.count), desktop: \(model.desktop.count)
                    Source errors: \(model.errors.keys.sorted().joined(separator: ", "))
                    Notifications: \(model.notificationPermission)
                    """
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    message = "Diagnostics copied. No credentials, task text, or conversation content are included."
                }
            }.padding(.vertical, 12)
            Divider().frame(width: 420)
            Text("Diagnostics include app and connection status.\nNever credentials, task text, or conversation content.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(30)
    }

    func label(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
    }

    func source(_ title: String, symbol: String, enabled: Binding<Bool>, status: String) -> some View {
        Toggle(isOn: enabled) {
            HStack(spacing: 10) {
                Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 24)
                Text(title)
                Spacer()
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    func sourceStatus(error: String, count: Int) -> String {
        if model.errors[error] != nil { return "Unavailable" }
        if !model.loaded { return "Checking…" }
        return count > 0 ? "\(count) sessions" : "No sessions"
    }

    func desktopStatus(app: String, bundle: String) -> String {
        if model.errors["desktop"] != nil { return "Unavailable" }
        let count = model.desktop.filter { $0.app == app }.count
        if count > 0 { return "\(count) sessions" }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) == nil ? "Not installed" : "No sessions"
    }

    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { message = "Couldn’t change the login item: \(error.localizedDescription)" }
        loginStatus = SMAppService.mainApp.status
    }
}

extension NSScreen {
    var displayID: String { String((deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0) }
}
