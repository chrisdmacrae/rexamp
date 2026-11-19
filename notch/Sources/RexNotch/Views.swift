import SwiftUI

enum Mode: Equatable {
    case idle // nothing running: the notch alone
    case compact // agents running: an icon and a count beside the notch
    case peek // an agent just finished or failed
    case ask // an agent needs an answer
    case list // hovering: every agent
}

enum Palette {
    static let working = Color(red: 0.29, green: 0.62, blue: 1)
    static let done = Color(red: 0.2, green: 0.82, blue: 0.4)
    static let blocked = Color(red: 1, green: 0.58, blue: 0.16)
    static let error = Color(red: 1, green: 0.3, blue: 0.27)
    static let idle = Color(white: 0.5)
    static let question = Color(red: 0.13, green: 0.7, blue: 0.85)
    static let option = Color(red: 0.04, green: 0.11, blue: 0.13)
    static let optionKey = Color(red: 0.06, green: 0.25, blue: 0.29)

    static func state(_ s: String) -> Color {
        switch s {
        case "working": working
        case "done": done
        case "blocked": blocked
        case "error": error
        default: idle
        }
    }
}

struct NotchView: View {
    @EnvironmentObject var model: NotchModel
    @EnvironmentObject var shape: ShapeBox
    let geometry: NotchGeometry
    let menu: () -> [MenuItem]

    static let wing: CGFloat = 44

    var mode: Mode {
        if model.hovering { return .list }
        if model.asking != nil { return .ask }
        if model.peek != nil || model.peekDesktop != nil { return .peek }
        if !model.agents.isEmpty || !model.remote.isEmpty || !model.desktop.isEmpty { return .compact }
        return .idle
    }

    var width: CGFloat {
        switch mode {
        case .idle: geometry.width
        case .compact: geometry.width + 2 * Self.wing
        case .peek: max(geometry.width + 2 * Self.wing, 460)
        case .ask, .list: 500
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if mode != .idle { wings }
            Group {
                switch mode {
                case .idle, .compact: EmptyView()
                case .peek:
                    if let a = model.peek { PeekRow(agent: a) } else if let d = model.peekDesktop { DesktopPeekRow(session: d) }
                case .ask: model.asking.map { AskCard(agent: $0) }
                case .list: AgentList()
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
        }
        .frame(width: width, alignment: .top)
        .frame(minHeight: geometry.height, alignment: .top)
        .background(alignment: .top) {
            NotchShape(bottomRadius: mode == .idle || mode == .compact ? 10 : 22)
                .fill(.black)
                .shadow(color: .black.opacity(mode == .idle || mode == .compact ? 0 : 0.45), radius: 14, y: 6)
        }
        .opacity(mode == .idle && !geometry.hasNotch ? 0 : 1)
        .background(GeometryReader { g in
            Color.clear.onAppear { shape.size = g.size }.onChange(of: g.size) { _, s in shape.size = s }
        })
        .contextMenu {
            ForEach(menu()) { item in Button(item.title, action: item.action) }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: mode)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: model.asking)
        .preferredColorScheme(.dark)
    }

    /// The icon left of the notch and the count right of it.
    var wings: some View {
        let top = model.topState
        return HStack(spacing: 0) {
            PixelIcon(color: Palette.state(top), working: top == "working")
                .frame(width: Self.wing)
            Spacer(minLength: geometry.width)
            Text("\(max(model.activeCount, model.agents.count + model.desktop.count))")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.75))
                .frame(minWidth: 18, minHeight: 18)
                .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.12)))
                .frame(width: Self.wing)
        }
        .frame(height: geometry.height)
    }
}

/// The notch outline: square top with small outward flares, round bottom.
struct NotchShape: Shape {
    var bottomRadius: CGFloat
    var topRadius: CGFloat = 6

    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in r: CGRect) -> Path {
        let t = topRadius, b = min(bottomRadius, r.height / 2)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + t, y: r.minY + t), control: CGPoint(x: r.minX + t, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + t, y: r.maxY - b))
        p.addQuadCurve(to: CGPoint(x: r.minX + t + b, y: r.maxY), control: CGPoint(x: r.minX + t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t - b, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - t, y: r.maxY - b), control: CGPoint(x: r.maxX - t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t, y: r.minY + t))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - t, y: r.minY))
        p.closeSubpath()
        return p
    }
}

/// A little pixel creature, tinted by state; it hops while its agent works.
struct PixelIcon: View {
    var color: Color
    var working = false
    static let rows = [
        "..X...X..",
        ".XXXXXXX.",
        "XX.XXX.XX",
        "XXXXXXXXX",
        ".X.X.X.X.",
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.12, paused: !working)) { tl in
            let hop = working ? Int(tl.date.timeIntervalSinceReferenceDate * 4) % 2 : 0
            Canvas { ctx, size in
                let px: CGFloat = 2
                let w = CGFloat(Self.rows[0].count) * px, h = CGFloat(Self.rows.count) * px
                let ox = (size.width - w) / 2, oy = (size.height - h) / 2 - CGFloat(hop)
                for (y, row) in Self.rows.enumerated() {
                    for (x, c) in row.enumerated() where c == "X" {
                        ctx.fill(Path(CGRect(x: ox + CGFloat(x) * px, y: oy + CGFloat(y) * px, width: px, height: px)), with: .color(color))
                    }
                }
            }
        }
        .frame(width: 22, height: 16)
    }
}

struct Tag: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.55))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.09)))
    }
}

func ago(_ d: Date?, now: Date = .now) -> String {
    guard let d else { return "" }
    let s = now.timeIntervalSince(d)
    switch s {
    case ..<60: return "now"
    case ..<3600: return "\(Int(s / 60))m"
    case ..<(48 * 3600): return "\(Int(s / 3600))h"
    default: return "\(Int(s / 86400))d"
    }
}

// MARK: Peek

struct PeekRow: View {
    @EnvironmentObject var model: NotchModel
    let agent: Agent

    var body: some View {
        HStack(spacing: 12) {
            PixelIcon(color: Palette.state(agent.state))
            Text(agent.task)
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
            Spacer()
            Text(agent.state == "done" ? "Done" : "Failed")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.state(agent.state))
        }
        .padding(.horizontal, 22)
        .padding(.top, 4)
        .padding(.bottom, 14)
        .contentShape(Rectangle())
        .onTapGesture { model.focus(agent) }
    }
}

// MARK: List

struct AgentList: View {
    @EnvironmentObject var model: NotchModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { tl in
            VStack(alignment: .leading, spacing: 2) {
                header
                if let a = model.asking {
                    AskCard(agent: a).padding(.horizontal, -18).padding(.bottom, 4)
                }
                ForEach(model.items) { item in
                    switch item {
                    case .pane(let a): AgentRow(agent: a, now: tl.date)
                    case .desktop(let d): DesktopRow(session: d, now: tl.date)
                    }
                }
                ForEach(model.remote) { t in
                    RemoteRow(thread: t, now: tl.date)
                }
                if !model.loaded {
                    note("Reading Rex…")
                } else if model.agents.isEmpty && model.remote.isEmpty && model.desktop.isEmpty {
                    note("No agents running")
                }
                if let e = model.errors["rex"] { note(e, color: Palette.error) }
                if let s = model.status { note(s, color: Palette.blocked) }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 14)
        }
    }

    @ViewBuilder var header: some View {
        if let u = model.usage {
            HStack(spacing: 6) {
                Image(systemName: "sparkle").foregroundStyle(Color(red: 0.95, green: 0.45, blue: 0.25))
                Text(u.credits_usd >= 0 ? String(format: "$%.2f", u.credits_usd) : "credits ?")
                    .foregroundStyle(u.low ? Palette.error : .white)
                    .fontWeight(.semibold)
                Text("left").foregroundStyle(.white.opacity(0.45))
                if let t = u.today_cost {
                    Text("|").foregroundStyle(.white.opacity(0.25))
                    Text("today").fontWeight(.semibold)
                    Text(t).foregroundStyle(Palette.done)
                }
                if let w = u.week_cost {
                    Text("|").foregroundStyle(.white.opacity(0.25))
                    Text("7d").fontWeight(.semibold)
                    Text(w).foregroundStyle(Palette.done)
                }
            }
            .font(.system(size: 12.5, design: .monospaced))
            .padding(.horizontal, 2)
            .padding(.bottom, model.subscriptions.isEmpty ? 6 : 2)
        }
        ForEach(model.subscriptions) { sub in
            SubscriptionRow(sub: sub)
        }
        if !model.subscriptions.isEmpty { Spacer().frame(height: 4) }
    }

    func note(_ s: String, color: Color = .white.opacity(0.45)) -> some View {
        Text(s).font(.system(size: 12)).foregroundStyle(color).lineLimit(2).padding(.vertical, 6).padding(.horizontal, 2)
    }
}

/// One line per subscription: each limit window's use, and when it resets.
struct SubscriptionRow: View {
    let sub: Subscription

    static func color(_ p: Double) -> Color {
        p >= 90 ? Palette.error : p >= 75 ? Palette.blocked : Palette.done
    }

    static func short(_ label: String) -> String {
        ["5-hour": "5h", "weekly": "7d", "weekly Opus": "7d Opus", "weekly Sonnet": "7d Sonnet"][label] ?? label
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: sub.name == "Codex" ? "chevron.left.forwardslash.chevron.right" : "asterisk")
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 14)
            Text(sub.name).fontWeight(.semibold)
            if let e = sub.error, sub.windows.isEmpty {
                Text(e).foregroundStyle(Palette.error).lineLimit(1)
            }
            ForEach(sub.windows, id: \.label) { w in
                Text("|").foregroundStyle(.white.opacity(0.25))
                Text(Self.short(w.label)).foregroundStyle(.white.opacity(0.7))
                Text(String(format: "%.0f%%", w.percent)).foregroundStyle(Self.color(w.percent))
                if let r = w.resets_at {
                    Text("↻" + ago(.now, now: r)).foregroundStyle(.white.opacity(0.45))
                }
            }
            if sub.error != nil && !sub.windows.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.error).help(sub.error ?? "")
            }
        }
        .font(.system(size: 12.5, design: .monospaced))
        .lineLimit(1)
        .padding(.horizontal, 2)
    }
}

struct AgentRow: View {
    @EnvironmentObject var model: NotchModel
    let agent: Agent
    let now: Date
    @State private var hover = false

    var expanded: Bool { ["done", "blocked", "error"].contains(agent.state) }

    var stateLine: String {
        switch agent.state {
        case "done": return "Done — click to jump"
        case "error": return "Failed" + (agent.msg.map { " — \($0)" } ?? "")
        case "blocked":
            let why = ["permission": "needs permission", "question": "has a question", "auth": "needs login"][agent.kind ?? ""] ?? "needs you"
            return "Waiting — \(agent.name) \(why)"
        default: return ""
        }
    }

    var body: some View {
        HStack(alignment: expanded ? .top : .center, spacing: 12) {
            Group {
                if expanded {
                    PixelIcon(color: Palette.state(agent.state))
                } else {
                    Circle().fill(Palette.state(agent.state)).frame(width: 8, height: 8)
                        .opacity(agent.state == "working" ? (hover ? 1 : 0.95) : 1)
                }
            }
            .frame(width: 22)
            .padding(.top, expanded ? 2 : 0)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(agent.task)
                        .font(.system(size: expanded ? 15 : 14, weight: expanded ? .semibold : .regular))
                        .foregroundStyle(.white.opacity(expanded ? 1 : 0.8))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Tag(text: agent.name)
                    Tag(text: agent.session)
                    Text(ago(agent.since, now: now))
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.45))
                        .frame(minWidth: 26, alignment: .trailing)
                }
                if expanded {
                    if let m = agent.msg, !m.isEmpty, m != agent.task, agent.state != "error" {
                        Text(m).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                    }
                    Text(stateLine).font(.system(size: 12.5)).foregroundStyle(Palette.state(agent.state)).lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, expanded ? 12 : 9)
        .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(expanded ? 0.07 : hover ? 0.05 : 0)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { model.focus(agent) }
        .help(agent.cwd)
    }
}

struct RemoteRow: View {
    @EnvironmentObject var model: NotchModel
    let thread: RemoteThread
    let now: Date
    @State private var hover = false

    var body: some View {
        HStack(spacing: 12) {
            Circle().strokeBorder(Palette.state(thread.state), lineWidth: 1.5).frame(width: 8, height: 8).frame(width: 22)
            Text(thread.title).font(.system(size: 14)).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
            Spacer(minLength: 8)
            Tag(text: "Amp")
            Tag(text: "outside Rex")
            Text(ago(thread.updated, now: now)).font(.system(size: 12)).foregroundStyle(.white.opacity(0.45)).frame(minWidth: 26, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(hover ? 0.05 : 0)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { model.open(thread) }
    }
}

/// A Claude or ChatGPT desktop session; clicking brings that app forward.
struct DesktopRow: View {
    @EnvironmentObject var model: NotchModel
    let session: DesktopSession
    let now: Date
    @State private var hover = false

    var expanded: Bool { ["done", "blocked", "error"].contains(session.state) }

    var stateLine: String {
        switch session.state {
        case "done": return "Done — click to open \(session.name)"
        case "blocked":
            return "Waiting — \(session.name) " + (session.kind == "permission" ? "needs permission" : "has a question")
        default: return ""
        }
    }

    var body: some View {
        HStack(alignment: expanded ? .top : .center, spacing: 12) {
            Group {
                if expanded {
                    PixelIcon(color: Palette.state(session.state))
                } else {
                    Circle().fill(Palette.state(session.state)).frame(width: 8, height: 8)
                }
            }
            .frame(width: 22)
            .padding(.top, expanded ? 2 : 0)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(session.task)
                        .font(.system(size: expanded ? 15 : 14, weight: expanded ? .semibold : .regular))
                        .foregroundStyle(.white.opacity(expanded ? 1 : 0.8))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Tag(text: session.name)
                    Tag(text: "Desktop")
                    Text(ago(session.since, now: now))
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.45))
                        .frame(minWidth: 26, alignment: .trailing)
                }
                if expanded {
                    Text(stateLine).font(.system(size: 12.5)).foregroundStyle(Palette.state(session.state)).lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, expanded ? 12 : 9)
        .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(expanded ? 0.07 : hover ? 0.05 : 0)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { model.open(session) }
        .help(session.cwd)
    }
}

struct DesktopPeekRow: View {
    @EnvironmentObject var model: NotchModel
    let session: DesktopSession

    var body: some View {
        HStack(spacing: 12) {
            PixelIcon(color: Palette.state(session.state))
            Text(session.task)
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
            Spacer()
            Text(session.state == "blocked" ? "\(session.name) needs you" : "\(session.name) done")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.state(session.state))
        }
        .padding(.horizontal, 22)
        .padding(.top, 4)
        .padding(.bottom, 14)
        .contentShape(Rectangle())
        .onTapGesture { model.open(session) }
    }
}

// MARK: Ask

/// What a blocked agent is asking, with its choices as buttons.
struct AskCard: View {
    @EnvironmentObject var model: NotchModel
    let agent: Agent

    var permission: Bool { agent.kind == "permission" }
    var options: [Option] { agent.prompt?.options ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            title
            if let pv = agent.prompt?.preview, !pv.isEmpty { PreviewBox(lines: pv) }
            if permissionTitle != nil, let q = agent.prompt?.question, !q.isEmpty {
                Text(q).font(.system(size: 13)).foregroundStyle(.white.opacity(0.55))
            }
            if options.isEmpty {
                wideButton("Show in Rex", primary: true) { model.focus(agent) }
            } else if permission && options.count >= 2 {
                ForEach(Array(options.enumerated().dropFirst().dropLast()), id: \.offset) { i, o in
                    optionRow(i, o)
                }
                HStack(spacing: 12) {
                    wideButton(short(options.last!.label, fallback: "Deny"), primary: false) { model.choose(agent, option: options.count - 1) }
                    wideButton(short(options.first!.label, fallback: "Allow"), primary: true) { model.choose(agent, option: 0) }
                }
            } else {
                ForEach(Array(options.enumerated()), id: \.offset) { i, o in optionRow(i, o) }
            }
            footer
        }
        .padding(.horizontal, 24)
        .padding(.top, 6)
        .padding(.bottom, 18)
    }

    var header: some View {
        HStack(spacing: 8) {
            switch agent.kind {
            case "question":
                Image(systemName: "bubble.left.fill").foregroundStyle(Palette.question)
                Text("\(agent.name) asks").foregroundStyle(Palette.question).fontWeight(.semibold)
            case "permission":
                Circle().fill(Palette.blocked.opacity(0.85)).frame(width: 9, height: 9)
                Text("Permission Request").foregroundStyle(.white.opacity(0.5))
            case "auth":
                Image(systemName: "key.fill").foregroundStyle(Palette.blocked)
                Text("\(agent.name) needs you to log in").foregroundStyle(.white.opacity(0.5))
            default:
                Circle().fill(Palette.blocked.opacity(0.85)).frame(width: 9, height: 9)
                Text("\(agent.name) needs you").foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
            Tag(text: agent.session)
            Button { model.dismiss(agent) } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.4))
            }
            .buttonStyle(.plain)
            .help("Hide until it asks again")
        }
        .font(.system(size: 15))
    }

    @ViewBuilder var title: some View {
        if let (tool, target) = permissionTitle {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Palette.blocked)
                Text(tool).foregroundStyle(Palette.blocked).fontWeight(.bold)
                Text(target).foregroundStyle(.white).lineLimit(1).truncationMode(.middle)
            }
            .font(.system(size: 17, design: .monospaced))
        } else {
            Text(agent.prompt?.question ?? agent.msg ?? agent.task)
                .font(.system(size: 17))
                .foregroundStyle(.white.opacity(0.92))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "approve Update: /tmp/x/a.txt" from Claude Code reads as Update a.txt.
    var permissionTitle: (String, String)? {
        if permission, let m = agent.msg, !m.isEmpty {
            let s = m.hasPrefix("approve ") ? String(m.dropFirst(8)) : m
            if let colon = s.firstIndex(of: ":") {
                let target = s[s.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                let short = target.hasPrefix("/") ? (target as NSString).lastPathComponent : target
                return (String(s[..<colon]), short)
            }
            return (s, "")
        }
        return nil
    }

    var footer: some View {
        HStack {
            Button { model.focus(agent) } label: {
                Text("Show in Rex").font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
            }
            .buttonStyle(.plain)
            Spacer()
            let more = model.waiting.count - 1
            if more > 0 {
                Text("+\(more) more waiting").font(.system(size: 12)).foregroundStyle(Palette.blocked.opacity(0.8))
            }
        }
    }

    func optionRow(_ i: Int, _ o: Option) -> some View {
        Button { model.choose(agent, option: i) } label: {
            HStack(spacing: 12) {
                Text(o.key)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Palette.optionKey))
                VStack(alignment: .leading, spacing: 2) {
                    Text(o.label).font(.system(size: 14.5)).foregroundStyle(.white.opacity(0.88)).lineLimit(1)
                    if let d = o.detail {
                        Text(d).font(.system(size: 12)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10).fill(Palette.option))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }

    func wideButton(_ label: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(primary ? .black : .white.opacity(0.88))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(RoundedRectangle(cornerRadius: 10).fill(primary ? Color(white: 0.9) : Color(white: 0.17)))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }

    /// "Yes" and "No" read better as Allow and Deny; keep other labels.
    func short(_ label: String, fallback: String) -> String {
        let l = label.lowercased()
        if l == "yes" || l.hasPrefix("yes,") || l == "no" || l.hasPrefix("no,") { return fallback }
        return label
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// The lines above a prompt, such as a diff, with added and removed lines tinted.
struct PreviewBox: View {
    let lines: [String]
    static let diff = try! NSRegularExpression(pattern: #"^\s*\d+\s*([+-])"#)

    func kind(_ l: String) -> Character? {
        guard let m = Self.diff.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)),
              let r = Range(m.range(at: 1), in: l) else { return nil }
        return l[r].first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.prefix(10).enumerated()), id: \.offset) { _, l in
                let k = kind(l)
                Text(l.isEmpty ? " " : l)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(k == "+" ? Palette.done : k == "-" ? Color(red: 1, green: 0.55, blue: 0.5) : .white.opacity(0.5))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 2.5)
                    .background(k == "+" ? Palette.done.opacity(0.1) : k == "-" ? Palette.error.opacity(0.13) : .clear)
            }
        }
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.05)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
