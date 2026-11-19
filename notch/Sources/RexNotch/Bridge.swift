import AppKit
import Foundation

// What `amp-rex-hud -json` writes; see stream.go.

struct Option: Decodable, Hashable {
    let key: String
    let label: String
    let detail: String?
}

struct Prompt: Decodable, Hashable {
    let question: String
    let options: [Option]
    let selected: Int
    let preview: [String]?
}

struct Agent: Decodable, Identifiable, Hashable {
    let block: String
    let host: String
    let session: String
    let window: String
    let agent: String
    let name: String
    let task: String
    let cwd: String
    let state: String
    let kind: String?
    let msg: String?
    let since: Date?
    let ports: [Int]?
    let prompt: Prompt?
    let question: String? // what it asked at the end of its turn, when done
    var id: String { block }

    /// It finished by asking you something, so it waits on you like a blocked one.
    var asks: Bool { state == "done" && question != nil }
    /// The state to show: one that asks counts as blocked.
    var shownState: String { asks ? "blocked" : state }
}

struct RemoteThread: Decodable, Identifiable, Hashable {
    let id: String
    let title: String
    let state: String
    let updated: Date
}

/// A session in the Claude or ChatGPT desktop app.
struct DesktopSession: Decodable, Identifiable, Hashable {
    let id: String
    let app: String
    let name: String
    let bundle: String
    let task: String
    let cwd: String
    let state: String
    let kind: String?
    let since: Date?
}

struct Usage: Decodable, Hashable {
    let credits: String
    let credits_usd: Double
    let week_cost: String?
    let today_cost: String?
    let low: Bool
}

/// A rate limit window of a Claude or ChatGPT subscription.
struct LimitWindow: Decodable, Hashable {
    let label: String
    let percent: Double
    let resets_at: Date?
}

/// Claude Code's or Codex's subscription limits.
struct Subscription: Decodable, Hashable, Identifiable {
    let name: String
    let plan: String?
    let windows: [LimitWindow]
    let error: String?
    var id: String { name }
}

private struct Line: Decodable {
    let type: String
    let agents: [Agent]?
    let remote: [RemoteThread]?
    let desktop: [DesktopSession]?
    let usage: Usage?
    let subscriptions: [Subscription]?
    let errors: [String: String]?
    let message: String?
}

/// Runs amp-rex-hud in JSON mode, restarting it if it exits, and passes each
/// line it writes to onLine on the main queue.
final class Bridge {
    private var process: Process?
    private var stdin: FileHandle?
    private var buffer = Data()
    private let onLine: (Data) -> Void

    init(onLine: @escaping (Data) -> Void) {
        self.onLine = onLine
    }

    static func executable() -> URL? {
        if let p = ProcessInfo.processInfo.environment["REXNOTCH_HUD"] { return URL(fileURLWithPath: p) }
        if let u = Bundle.main.url(forAuxiliaryExecutable: "amp-rex-hud") { return u }
        let u = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/amp-rex-hud")
        return FileManager.default.isExecutableFile(atPath: u.path) ? u : nil
    }

    func start() {
        guard let exe = Bridge.executable() else {
            onLine(#"{"type":"status","message":"amp-rex-hud not found; run notch/build.sh"}"#.data(using: .utf8)!)
            return
        }
        let p = Process()
        p.executableURL = exe
        p.arguments = ["-json", "-notify=false"]
        let out = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardInput = inp
        p.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            DispatchQueue.main.async { self?.receive(d) }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self?.start() }
        }
        do {
            try p.run()
            process = p
            stdin = inp.fileHandleForWriting
        } catch {
            onLine(try! JSONEncoder().encode(["type": "status", "message": "Couldn't start amp-rex-hud: \(error.localizedDescription)"]))
        }
    }

    func stop() {
        process?.terminationHandler = nil
        process?.terminate()
    }

    func send(_ command: [String: Any]) {
        guard let stdin, var d = try? JSONSerialization.data(withJSONObject: command) else { return }
        d.append(0x0A)
        try? stdin.write(contentsOf: d)
    }

    private func receive(_ d: Data) {
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if !line.isEmpty { onLine(Data(line)) }
        }
    }
}

@MainActor
final class NotchModel: ObservableObject {
    @Published var agents: [Agent] = []
    @Published var remote: [RemoteThread] = []
    @Published var desktop: [DesktopSession] = []
    @Published var usage: Usage?
    @Published var subscriptions: [Subscription] = []
    @Published var errors: [String: String] = [:]
    @Published var status: String?
    @Published var hovering = false // the pointer is over the notch
    @Published var expanded = false // the list is open, by a click on the notch
    @Published var notifies = false // macOS notifications are allowed
    @Published var peek: Agent?
    @Published private(set) var dismissed: Set<String> = []
    @Published var loaded = false

    private var bridge: Bridge!
    private var peekTimer: Timer?
    private var statusTimer: Timer?

    private let notifier = Notifier()

    init() {
        bridge = Bridge { [weak self] d in self?.handle(d) }
    }

    func start() {
        notifier.start(self)
        bridge.start()
    }
    func stop() { bridge.stop() }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        // Go writes RFC 3339 with up to nine fractional digits, which
        // ISO8601DateFormatter can't read, so drop them.
        let frac = try! NSRegularExpression(pattern: #"\.\d+"#)
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            let t = frac.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
            guard let date = ISO8601DateFormatter().date(from: t) else {
                throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: s))
            }
            return date
        }
        return d
    }()

    private func handle(_ d: Data) {
        guard let line = try? Self.decoder.decode(Line.self, from: d) else { return }
        switch line.type {
        case "snapshot":
            let new = line.agents ?? []
            let newDesktop = line.desktop ?? []
            if loaded {
                notice(old: agents, new: new)
                noticeDesktop(old: desktop, new: newDesktop)
            }
            agents = new
            remote = line.remote ?? []
            desktop = newDesktop
            usage = line.usage ?? usage
            subscriptions = line.subscriptions ?? subscriptions
            errors = line.errors ?? [:]
            loaded = true
        case "status":
            show(line.message ?? "")
        default:
            break
        }
    }

    /// Notifies when an agent finishes, fails, or needs you, or peeks at one
    /// that finished or failed when notifications aren't allowed.
    private func notice(old: [Agent], new: [Agent]) {
        let was = Dictionary(old.map { ($0.block, $0.state) }, uniquingKeysWith: { a, _ in a })
        for a in new where was[a.block] != nil && a.state != was[a.block] {
            if was[a.block] == "blocked" { notifier.remove(id: a.block) }
            guard ["done", "error", "blocked"].contains(a.state) else { continue }
            if notifies {
                let what = a.asks ? "asks" : ["done": "finished", "error": "failed", "blocked": "needs you"][a.state]!
                let body = a.question ?? (a.state == "blocked" ? (a.prompt?.question ?? a.msg ?? a.task) : a.task)
                let permission = a.kind == "permission" && (a.prompt?.options.count ?? 0) >= 2
                notifier.post(id: a.block, title: "\(a.name) \(what)", subtitle: a.session, body: body,
                              urgent: a.shownState != "done", permission: permission, reply: a.state == "done", info: ["block": a.block])
                continue
            }
            if a.shownState == "blocked" { continue } // the notch shows the question
            peek = a
            peekTimer?.invalidate()
            peekTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.peek = nil }
            }
        }
    }

    @Published var peekDesktop: DesktopSession?

    /// Peeks at a desktop session that just finished or started waiting.
    private func noticeDesktop(old: [DesktopSession], new: [DesktopSession]) {
        let was = Dictionary(old.map { ($0.id, $0.state) }, uniquingKeysWith: { a, _ in a })
        for s in new where was[s.id] != nil && s.state != was[s.id] && (s.state == "blocked" || (s.state == "done" && was[s.id] == "working")) {
            if notifies {
                notifier.post(id: "desktop-" + s.id, title: "\(s.name) " + (s.state == "blocked" ? "needs you" : "finished"),
                              subtitle: "", body: s.task, urgent: s.state == "blocked", info: ["desktop": s.id])
                continue
            }
            peekDesktop = s
            peekTimer?.invalidate()
            peekTimer = Timer.scheduledTimer(withTimeInterval: s.state == "blocked" ? 12 : 6, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.peekDesktop = nil }
            }
        }
    }

    private func show(_ message: String) {
        status = message
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.status = nil }
        }
    }

    // MARK: What to show

    static let rank = ["blocked": 5, "error": 4, "done": 3, "working": 2, "idle": 1]

    /// Agents, most urgent first, then most recently changed.
    var sorted: [Agent] {
        agents.sorted {
            let (a, b) = (Self.rank[$0.shownState] ?? 0, Self.rank[$1.shownState] ?? 0)
            if a != b { return a > b }
            return ($0.since ?? .distantPast) > ($1.since ?? .distantPast)
        }
    }

    /// A key that changes each time an agent asks something new.
    static func askKey(_ a: Agent) -> String { a.block + "|" + (a.since.map { "\($0.timeIntervalSince1970)" } ?? "") + "|" + (a.prompt?.question ?? a.question ?? "") }

    var waiting: [Agent] { sorted.filter { $0.shownState == "blocked" } }
    var asking: Agent? { waiting.first { !dismissed.contains(Self.askKey($0)) } }
    var activeCount: Int {
        agents.filter { $0.state != "idle" }.count + remote.filter { $0.state != "idle" }.count + desktop.filter { $0.state != "idle" }.count
    }

    enum Item: Identifiable {
        case pane(Agent)
        case desktop(DesktopSession)
        var id: String {
            switch self {
            case .pane(let a): "p" + a.id
            case .desktop(let d): "d" + d.app + d.id
            }
        }
        var state: String {
            switch self {
            case .pane(let a): a.shownState
            case .desktop(let d): d.state
            }
        }
        var since: Date? {
            switch self {
            case .pane(let a): a.since
            case .desktop(let d): d.since
            }
        }
    }

    /// Rex agents and desktop sessions together, most urgent first.
    var items: [Item] {
        (agents.map(Item.pane) + desktop.map(Item.desktop)).sorted {
            let (a, b) = (Self.rank[$0.state] ?? 0, Self.rank[$1.state] ?? 0)
            if a != b { return a > b }
            return ($0.since ?? .distantPast) > ($1.since ?? .distantPast)
        }
    }

    /// The most urgent state of anything shown, for the icon beside the notch.
    var topState: String {
        let states = agents.map(\.shownState) + desktop.map(\.state)
        return states.max { (Self.rank[$0] ?? 0) < (Self.rank[$1] ?? 0) } ?? "idle"
    }

    func dismiss(_ a: Agent) { dismissed.insert(Self.askKey(a)) }

    // MARK: Actions

    func focus(_ a: Agent) {
        bridge.send(["op": "focus", "block": a.block])
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.superlogical.rex").map {
            NSWorkspace.shared.openApplication(at: $0, configuration: .init())
        }
        expanded = false
        peek = nil
    }

    func choose(_ a: Agent, option: Int) {
        bridge.send(["op": "choose", "block": a.block, "option": option])
        dismiss(a) // hide it until the agent asks again
        // Claude Code's "Type something." and "Chat about this" want typing.
        if let l = a.prompt?.options[option].label, l.hasPrefix("Type something") || l.hasPrefix("Chat about") {
            focus(a)
        }
    }

    /// Types an answer into the agent's pane and presses Return.
    func reply(_ a: Agent, text: String) {
        bridge.send(["op": "reply", "block": a.block, "text": text])
        dismiss(a) // hide it until the agent asks again
    }

    func open(_ t: RemoteThread) {
        NSWorkspace.shared.open(URL(string: "https://ampcode.com/threads/\(t.id)")!)
        expanded = false
    }

    func open(_ s: DesktopSession) {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: s.bundle) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
        expanded = false
        peekDesktop = nil
    }

    func refresh() { bridge.send(["op": "refresh"]) }
}
