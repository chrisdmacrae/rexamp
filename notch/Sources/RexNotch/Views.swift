import AppKit
import SwiftUI

enum Mode: Equatable {
    case idle // nothing running: the notch alone
    case compact // agents running: the dinosaur and a count beside the notch
    case peek // an agent just finished or failed, and notifications are off
    case ask // an agent needs an answer
    case list // clicked open: every agent and usage
}

/// System colors, so states match the rest of macOS in light and dark mode.
enum Palette {
    static let working = Color(nsColor: .systemBlue)
    static let done = Color(nsColor: .systemGreen)
    static let blocked = Color(nsColor: .systemOrange)
    static let error = Color(nsColor: .systemRed)
    static let idle = Color(nsColor: .systemGray)

    static func state(_ s: String) -> Color {
        switch s {
        case "working": working
        case "done": done
        case "blocked": blocked
        case "error": error
        default: idle
        }
    }

    /// The SF Symbol on a row's state badge.
    static func symbol(_ s: String) -> String {
        switch s {
        case "working": "ellipsis"
        case "done": "checkmark"
        case "blocked": "hand.raised.fill"
        case "error": "xmark"
        default: "minus"
        }
    }
}

let rexBundle = "com.superlogical.rex"

/// The popover material, kept active. SwiftUI's materials go flat grey in a
/// window that isn't key, and the notch's panel never is.
struct PopoverMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        v.wantsLayer = true
        v.layer?.cornerRadius = 12
        v.layer?.cornerCurve = .continuous
        v.layer?.masksToBounds = true
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

extension View {
    /// The look of a menu bar extra's panel: the popover material with a
    /// hairline edge.
    func panelStyle() -> some View {
        // A wash of the window color keeps text readable over dark content
        // in light mode, as Control Center does.
        background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .windowBackgroundColor).opacity(0.6)))
            .background(PopoverMaterial())
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }
}

struct NotchView: View {
    @EnvironmentObject var model: NotchModel
    @EnvironmentObject var shape: ShapeBox
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    let geometry: NotchGeometry
    let menu: () -> [MenuItem]

    static let wing: CGFloat = 44

    var mode: Mode {
        if model.expanded { return .list }
        // A waiting agent's choices show without a click, notification or not.
        if model.settings.values.showQuestions && model.asking != nil { return .ask }
        if model.visiblePeek != nil || model.visiblePeekDesktop != nil { return .peek }
        if !model.hasVisibleSessions { return .idle }
        return .compact
    }

    /// The strip shows its wings when anything runs, and when hovered so
    /// it's clear it can be clicked; hovering also widens it a little.
    var wings: Bool { mode != .idle || model.hovering || model.expanded || model.settings.values.showWhenIdle || model.updater.active }

    var stripWidth: CGFloat {
        wings ? geometry.width + 2 * (Self.wing + (model.hovering ? 6 : 0)) : geometry.width
    }

    var body: some View {
        VStack(spacing: 6) {
            strip
            if mode == .peek || mode == .ask || mode == .list {
                Group {
                    switch mode {
                    case .peek:
                        if let a = model.visiblePeek { AgentRow(agent: a, now: .now) } else if let d = model.visiblePeekDesktop { DesktopRow(session: d, now: .now) }
                    case .ask: model.asking.map { AskCard(agent: $0) }
                    default: AgentList()
                    }
                }
                .padding(mode == .list ? 0 : 6)
                .frame(width: mode == .peek ? 420 : 480)
                // The panel never activates the app, which would draw
                // accent colors grey, as in an inactive window.
                .environment(\.controlActiveState, .key)
                .panelStyle()
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -6)))
            }
        }
        .background(GeometryReader { g in
            Color.clear.onAppear { shape.size = g.size }.onChange(of: g.size) { _, s in shape.size = s }
        })
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: mode)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: model.hovering)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.asking)
    }

    /// The black strip that extends the notch: the dinosaur left of it and
    /// the count right of it. Clicking it opens the list.
    var strip: some View {
        HStack(spacing: 0) {
            if wings {
                let top = model.topState
                Group {
                    if model.updater.active {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 17, weight: .medium)).foregroundStyle(.white)
                            .accessibilityLabel("Updating RexNotch")
                    } else {
                        DinoIcon(color: Palette.state(top), working: top == "working" && !reduceMotion)
                    }
                }.frame(width: Self.wing)
                Spacer(minLength: geometry.width)
                Group {
                    if model.updater.active {
                        UpdateActivityIndicator().frame(width: 16, height: 16)
                            .accessibilityLabel(model.updater.status)
                            .help(model.updater.status)
                    } else {
                        Text("\(max(model.activeCount, model.visibleAgents.count + model.visibleDesktop.count))")
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.8))
                            .frame(minWidth: 18, minHeight: 18)
                            .background(Capsule().fill(.white.opacity(0.15)))
                    }
                }.frame(width: Self.wing)
            }
        }
        .frame(width: stripWidth, height: geometry.height)
        .background(NotchShape(bottomRadius: 10).fill(.black))
        .opacity(!wings && !geometry.hasNotch ? 0 : 1)
        .contentShape(Rectangle())
        .onTapGesture { model.expanded.toggle() }
        .contextMenu {
            ForEach(menu()) { item in Button(item.title, action: item.action) }
        }
    }
}

/// White activity spokes keep their contrast on the always-black notch.
struct UpdateActivityIndicator: View {
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12, paused: reduceMotion)) { timeline in
            Canvas { context, size in
                let phase = reduceMotion ? 0 : Int(timeline.date.timeIntervalSinceReferenceDate * 12) % 8
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                for i in 0..<8 {
                    let angle = Double(i) * .pi / 4
                    var spoke = Path()
                    spoke.move(to: CGPoint(x: center.x + 3 * cos(angle), y: center.y + 3 * sin(angle)))
                    spoke.addLine(to: CGPoint(x: center.x + 6 * cos(angle), y: center.y + 6 * sin(angle)))
                    let opacity = Double((i - phase + 8) % 8 + 1) / 8
                    context.stroke(spoke, with: .color(.white.opacity(opacity)), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                }
            }
        }
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

/// How long until d, such as "3h 12m" or "1d 22h".
func until(_ d: Date, now: Date = .now) -> String {
    let m = Int(d.timeIntervalSince(now) / 60)
    switch m {
    case ..<1: return "now"
    case ..<60: return "\(m)m"
    case ..<(24 * 60): return "\(m / 60)h \(m % 60)m"
    default: return "\(m / 1440)d \(m % 1440 / 60)h"
    }
}

// MARK: Rows

/// The app whose icon stands for an agent run in a Rex pane, if it has one.
func agentBundle(_ agent: String) -> String? {
    switch agent {
    case "claude": "com.anthropic.claudefordesktop"
    case "codex": "com.openai.codex"
    default: nil
    }
}

/// An app's icon with a badge for its agent's state, like a notification's,
/// and a smaller icon of the agent that runs in it, if any.
struct AppIcon: View {
    let bundle: String?
    var symbol = "terminal"
    let state: String
    var agent: String? = nil // bundle ID of the agent's app
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    @MainActor static var cache: [String: NSImage] = [:]

    @MainActor static func icon(_ bundle: String) -> NSImage? {
        if let i = cache[bundle] { return i }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return nil }
        let i = NSWorkspace.shared.icon(forFile: url.path)
        cache[bundle] = i
        return i
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let b = bundle, let i = Self.icon(b) {
                    Image(nsImage: i).resizable().interpolation(.high)
                } else {
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.quaternary)
                        .overlay(Image(systemName: symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary))
                        .padding(1)
                }
            }
            .frame(width: 30, height: 30)
            .overlay(alignment: .bottomTrailing) {
                if let a = agent, let i = Self.icon(a) {
                    Image(nsImage: i).resizable().interpolation(.high)
                        .frame(width: 16, height: 16)
                        .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
                        .offset(x: 4, y: 4)
                }
            }
            Image(systemName: Palette.symbol(state))
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 14, height: 14)
                .background(Circle().fill(Palette.state(state)))
                .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                .symbolEffect(.pulse, isActive: state == "working" && !reduceMotion)
                .offset(x: 3, y: -3)
        }
        .frame(width: 34, height: 34)
    }
}

/// A row like a notification: the app's icon, a title, a secondary line,
/// what it needs from you if anything, and the time.
struct ActivityRow: View {
    let bundle: String?
    var symbol = "terminal"
    let state: String
    let title: String
    let subtitle: String
    var detail: String?
    let time: String
    var help = ""
    var agent: String? = nil // bundle ID of the agent's app, badged on the icon
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                AppIcon(bundle: bundle, symbol: symbol, state: state, agent: agent)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(title).font(.headline).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(time).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    if let detail {
                        Text(detail).font(.subheadline).foregroundStyle(Palette.state(state)).lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(hover ? 0.07 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

struct AgentRow: View {
    @EnvironmentObject var model: NotchModel
    let agent: Agent
    let now: Date

    @State private var replying = false

    var stateLine: String? {
        if agent.asks { return "Has a question" }
        switch agent.state {
        case "done": return "Finished"
        case "error": return "Failed" + (agent.msg.map { ": \($0)" } ?? "")
        case "blocked":
            let why = ["permission": "Needs permission", "question": "Has a question", "auth": "Needs you to log in"][agent.kind ?? ""] ?? "Needs you"
            return why
        default: return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ActivityRow(bundle: rexBundle, state: agent.shownState, title: agent.task, subtitle: "\(agent.name) · \(agent.session)",
                        detail: stateLine, time: ago(agent.since, now: now), help: agent.cwd,
                        agent: agentBundle(agent.agent)) { model.focus(agent) }
                .overlay(alignment: .bottomTrailing) {
                    // A finished agent waits for your next message, so it takes one here.
                    if agent.state == "done" && !replying {
                        Button("Reply") { replying = true }
                            .buttonStyle(.link)
                            .font(.subheadline)
                            .padding(.trailing, 8)
                            .padding(.bottom, 6)
                    }
                }
            if replying {
                ReplyField(agent: agent) { replying = false }
                    .padding(.leading, 52)
                    .padding(.trailing, 8)
                    .padding(.bottom, 6)
            }
        }
    }
}

/// An Amp thread outside Rex; clicking opens it on ampcode.com.
struct RemoteRow: View {
    @EnvironmentObject var model: NotchModel
    let thread: RemoteThread
    let now: Date

    var body: some View {
        ActivityRow(bundle: nil, symbol: "globe", state: thread.state, title: thread.title, subtitle: "Amp · outside Rex",
                    time: ago(thread.updated, now: now)) { model.open(thread) }
    }
}

/// A Claude or ChatGPT desktop session; clicking brings that app forward.
struct DesktopRow: View {
    @EnvironmentObject var model: NotchModel
    let session: DesktopSession
    let now: Date

    var stateLine: String? {
        switch session.state {
        case "done": return "Finished"
        case "blocked": return session.kind == "permission" ? "Needs permission" : "Has a question"
        default: return nil
        }
    }

    var body: some View {
        ActivityRow(bundle: session.bundle, state: session.state, title: session.task, subtitle: "\(session.name) · Desktop",
                    detail: stateLine, time: ago(session.since, now: now), help: session.cwd) { model.open(session) }
    }
}

// MARK: List

/// The eye beside the list's title: shows or hides idle threads.
struct InactiveToggle: View {
    @EnvironmentObject var model: NotchModel

    var body: some View {
        let hidden = model.settings.values.hideInactive
        Button {
            model.settings.values.hideInactive.toggle()
        } label: {
            Image(systemName: hidden ? "eye.slash" : "eye")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(hidden ? "Show inactive" : "Hide inactive")
        .accessibilityLabel(hidden ? "Show inactive threads" : "Hide inactive threads")
    }
}

struct AgentList: View {
    @EnvironmentObject var model: NotchModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { tl in
            // Scrolls only when the list is taller than the screen.
            ViewThatFits(in: .vertical) {
                content(tl.date)
                ScrollView { content(tl.date) }
            }
        }
    }

    func content(_ now: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let a = model.asking {
                AskCard(agent: a)
                Divider()
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    sectionTitle("Agents")
                    Spacer()
                    InactiveToggle().padding(.trailing, 8).padding(.bottom, 4)
                }
                ForEach(model.listedItems) { item in
                    switch item {
                    case .pane(let a): AgentRow(agent: a, now: now)
                    case .desktop(let d): DesktopRow(session: d, now: now)
                    }
                }
                ForEach(model.listedRemote) { t in
                    RemoteRow(thread: t, now: now)
                }
                if !model.loaded {
                    note("Reading Rex…")
                } else if !model.hasVisibleSessions {
                    note("No agents running")
                } else if !model.hasListedSessions {
                    note("No active agents")
                }
                if model.settings.values.showRex, let e = model.errors["rex"] { note(e, color: Palette.error) }
                if let s = model.status { note(s, color: Palette.blocked) }
            }
            if model.showsUsage {
                Divider()
                UsageSection(now: now)
            }
        }
        .padding(10)
    }

    func sectionTitle(_ s: String) -> some View {
        Text(s).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.bottom, 4)
    }

    func note(_ s: String, color: Color = .secondary) -> some View {
        Text(s).font(.subheadline).foregroundStyle(color).lineLimit(2).padding(.vertical, 4).padding(.horizontal, 8)
    }
}

// MARK: Usage

/// Amp credits and each subscription's limits, drawn like the Battery menu.
struct UsageSection: View {
    @EnvironmentObject var model: NotchModel
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Usage").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            if let u = model.usage {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Amp").font(.headline)
                        Spacer()
                        Text(u.credits_usd >= 0 ? String(format: "$%.2f left", u.credits_usd) : "Credits unknown")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(u.low ? Palette.error : .primary)
                    }
                    let costs = [u.today_cost.map { "Today \($0)" }, u.week_cost.map { "7 days \($0)" }].compactMap { $0 }
                    if !costs.isEmpty {
                        Text(costs.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(model.subscriptions) { sub in
                SubscriptionView(sub: sub, now: now)
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }
}

struct SubscriptionView: View {
    let sub: Subscription
    let now: Date

    static func color(_ p: Double) -> Color {
        p >= 90 ? Palette.error : p >= 75 ? Palette.blocked : .accentColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(sub.name).font(.headline)
                if let p = sub.plan, !p.isEmpty {
                    Text(p.capitalized).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let e = sub.error, !sub.windows.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.blocked).help(e)
                }
            }
            if let e = sub.error, sub.windows.isEmpty {
                Text(e).font(.caption).foregroundStyle(Palette.error).lineLimit(2)
            }
            ForEach(sub.windows, id: \.label) { w in
                HStack(spacing: 8) {
                    Text(w.label.prefix(1).uppercased() + w.label.dropFirst())
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(width: 84, alignment: .leading)
                    // A capsule bar like the Battery menu's; Gauge ignores its tint on macOS.
                    GeometryReader { g in
                        Capsule().fill(.quaternary)
                            .overlay(alignment: .leading) {
                                Capsule().fill(Self.color(w.percent))
                                    .frame(width: max(6, g.size.width * min(max(w.percent, 0), 100) / 100))
                            }
                    }
                    .frame(height: 6)
                    Text(String(format: "%.0f%%", w.percent))
                        .font(.caption.monospacedDigit())
                        .frame(width: 34, alignment: .trailing)
                    Text(w.resets_at.map { "resets in " + until($0, now: now) } ?? "")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 96, alignment: .leading)
                }
            }
        }
    }
}

// MARK: Ask

/// What a blocked agent is asking, with its choices as standard buttons:
/// Return picks the default, Esc denies, and digits pick a numbered choice.
struct AskCard: View {
    @EnvironmentObject var model: NotchModel
    let agent: Agent

    var permission: Bool { agent.kind == "permission" }
    var options: [Option] { agent.prompt?.options ?? [] }
    /// A question without numbered choices takes a typed answer.
    var typed: Bool { options.isEmpty && agent.kind != "permission" && agent.kind != "auth" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            title
            if let pv = agent.prompt?.preview, !pv.isEmpty { PreviewBox(lines: pv) }
            if permissionTitle != nil, let q = agent.prompt?.question, !q.isEmpty {
                Text(q).font(.subheadline).foregroundStyle(.secondary)
            }
            buttons
            footer
        }
        .padding(8)
    }

    var headline: String {
        if agent.asks { return "\(agent.name) asks" }
        return switch agent.kind {
        case "question": "\(agent.name) asks"
        case "permission": "\(agent.name) wants permission"
        case "auth": "\(agent.name) needs you to log in"
        default: "\(agent.name) needs you"
        }
    }

    var header: some View {
        HStack(spacing: 10) {
            AppIcon(bundle: rexBundle, state: "blocked", agent: agentBundle(agent.agent))
            VStack(alignment: .leading, spacing: 1) {
                Text(headline).font(.headline)
                Text(agent.session).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.dismiss(agent) } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Hide until it asks again")
        }
    }

    @ViewBuilder var title: some View {
        if let (tool, target) = permissionTitle {
            (Text(tool).fontWeight(.semibold) + Text(" ") + Text(target))
                .font(.title3)
                .lineLimit(1)
                .truncationMode(.middle)
        } else {
            Text(agent.prompt?.question ?? agent.question ?? agent.msg ?? agent.task)
                .font(.title3)
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

    @ViewBuilder var buttons: some View {
        if typed {
            ReplyField(agent: agent).controlSize(.large)
        } else if options.isEmpty {
            HStack {
                Spacer()
                Button("Show in Rex") { model.focus(agent) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        } else if permission && options.count >= 2 {
            ForEach(Array(options.enumerated().dropFirst().dropLast()), id: \.offset) { i, o in
                optionButton(i, o)
            }
            HStack {
                Spacer()
                Button(short(options.last!.label, fallback: "Deny")) { model.choose(agent, option: options.count - 1) }
                    .keyboardShortcut(.cancelAction)
                Button(short(options.first!.label, fallback: "Allow")) { model.choose(agent, option: 0) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        } else {
            ForEach(Array(options.enumerated()), id: \.offset) { i, o in optionButton(i, o) }
        }
    }

    func optionButton(_ i: Int, _ o: Option) -> some View {
        Button { model.choose(agent, option: i) } label: {
            HStack(spacing: 8) {
                Text(o.key).font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(o.label).lineLimit(1)
                    if let d = o.detail {
                        Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .keyboardShortcut(KeyEquivalent(o.key.first ?? "?"), modifiers: [])
    }

    var footer: some View {
        HStack {
            Button("Show in Rex") { model.focus(agent) }
                .buttonStyle(.link)
                .font(.caption)
            Spacer()
            let more = model.waiting.count - 1
            if more > 0 {
                Text("\(more) more waiting").font(.caption).foregroundStyle(Palette.blocked)
            }
        }
    }

    /// "Yes" and "No" read better as Allow and Deny; keep other labels.
    func short(_ label: String, fallback: String) -> String {
        let l = label.lowercased()
        if l == "yes" || l.hasPrefix("yes,") || l == "no" || l.hasPrefix("no,") { return fallback }
        return label
    }
}

/// A text field that types an answer into an agent's pane and presses Return.
struct ReplyField: View {
    @EnvironmentObject var model: NotchModel
    let agent: Agent
    var sent: () -> Void = {}
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            TextField("Reply to \(agent.name)", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(send)
            Button("Send", action: send)
                .buttonStyle(.borderedProminent)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .onAppear { focused = true }
    }

    func send() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        model.reply(agent, text: t)
        text = ""
        sent()
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
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(k == "+" ? Palette.done : k == "-" ? Palette.error : .secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(k == "+" ? Palette.done.opacity(0.12) : k == "-" ? Palette.error.opacity(0.12) : .clear)
            }
        }
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.05)))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
