import XCTest
@testable import RexNotch

final class SettingsTests: XCTestCase {
    @MainActor
    func testPreferencesPersistAndFilterEveryNotchSurface() throws {
        let suite = "RexNotchTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = Settings(defaults: defaults)
        let model = NotchModel(settings: settings)
        let agent = Agent(block: "rex", host: "host", session: "session", window: "window", agent: "claude",
                          name: "Claude Code", task: "task", cwd: "/private", state: "blocked", kind: nil,
                          msg: nil, since: nil, ports: nil, prompt: nil, question: nil)
        model.agents = [agent]
        model.remote = [RemoteThread(id: "remote", title: "Remote", state: "working", updated: .now)]
        model.desktop = [
            DesktopSession(id: "claude", app: "claude", name: "Claude", bundle: "claude", task: "task", cwd: "", state: "error", kind: nil, since: nil),
            DesktopSession(id: "chatgpt", app: "chatgpt", name: "ChatGPT", bundle: "chatgpt", task: "task", cwd: "", state: "working", kind: nil, since: nil),
        ]
        model.peek = agent
        XCTAssertEqual(model.activeCount, 4)
        XCTAssertEqual(model.topState, "blocked")
        settings.values.showQuestions = false
        XCTAssertNotNil(model.asking) // Still accessible in the clicked-open list.
        XCTAssertEqual(model.waiting.count, 1)
        settings.values.showRex = false
        settings.values.showClaude = false
        XCTAssertNil(model.asking)
        XCTAssertNil(model.visiblePeek)
        XCTAssertEqual(model.items.count, 1)
        XCTAssertEqual(model.activeCount, 2)
        XCTAssertEqual(model.topState, "working")
        settings.values.showChatGPT = false
        settings.values.showRemote = false
        XCTAssertFalse(model.hasVisibleSessions)
        XCTAssertEqual(model.activeCount, 0)
        settings.values.display = "1234"
        settings.values.notifyCompletion = false
        settings.values.showPreviews = false
        settings.values.automaticUpdates = false
        XCTAssertEqual(Settings(defaults: defaults).values, settings.values)
    }

    @MainActor
    func testEyeHidesIdleThreadsFromTheList() throws {
        let suite = "RexNotchTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = Settings(defaults: defaults)
        let model = NotchModel(settings: settings)
        model.agents = [Agent(block: "rex", host: "host", session: "session", window: "window", agent: "claude",
                              name: "Claude Code", task: "task", cwd: "/", state: "idle", kind: nil,
                              msg: nil, since: nil, ports: nil, prompt: nil, question: nil)]
        model.remote = [RemoteThread(id: "a", title: "A", state: "idle", updated: .now),
                        RemoteThread(id: "b", title: "B", state: "working", updated: .now)]
        model.desktop = [DesktopSession(id: "c", app: "claude", name: "Claude", bundle: "claude", task: "t", cwd: "", state: "done", kind: nil, since: nil)]
        XCTAssertEqual(model.listedItems.count, 2)
        XCTAssertEqual(model.listedRemote.count, 2)
        settings.values.hideInactive = true
        XCTAssertEqual(model.listedItems.map(\.state), ["done"])
        XCTAssertEqual(model.listedRemote.map(\.id), ["b"])
        XCTAssertEqual(model.activeCount, 2) // the notch's count doesn't change
        XCTAssertTrue(Settings(defaults: defaults).values.hideInactive)
        model.remote = []
        model.desktop = []
        XCTAssertTrue(model.hasVisibleSessions)
        XCTAssertFalse(model.hasListedSessions)
    }

    func testPreferencesSavedBeforeANewSettingStillLoad() throws {
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(Preferences())) as? [String: Any])
        old.removeValue(forKey: "hideInactive")
        old["showRemote"] = false
        let values = try XCTUnwrap(Settings.decode(JSONSerialization.data(withJSONObject: old)))
        XCTAssertFalse(values.showRemote)
        XCTAssertFalse(values.hideInactive)
    }

    func testNotificationEventsAreIndependent() {
        var values = Preferences()
        values.notifyCompletion = false
        XCTAssertFalse(values.notifies(state: "done"))
        XCTAssertTrue(values.notifies(state: "blocked"))
        XCTAssertTrue(values.notifies(state: "error"))
        XCTAssertFalse(values.notifies(state: "working"))
        values.notifyInput = false
        XCTAssertFalse(values.notifies(state: "blocked"))
        XCTAssertTrue(values.notifies(state: "error"))
    }

}
