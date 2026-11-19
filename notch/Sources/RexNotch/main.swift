import AppKit
import ServiceManagement
import SwiftUI

// RexNotch shows the coding agents running in Rex panes around the MacBook
// notch: a count beside it, a peek when one finishes, the question or
// permission request when one needs you, and the full list on hover.

/// Where the notch is on a screen. Screens without one get a notch-sized
/// tab at the top of the menu bar.
struct NotchGeometry: Equatable {
    var width: CGFloat
    var height: CGFloat
    var hasNotch: Bool

    init(_ screen: NSScreen) {
        if screen.safeAreaInsets.top > 0,
           let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            width = screen.frame.width - l.width - r.width
            height = screen.safeAreaInsets.top
            hasNotch = true
        } else {
            width = 180
            height = NSStatusBar.system.thickness
            hasNotch = false
        }
    }

    static func screen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }
}

final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Lets the first click on the notch press a button rather than only
/// activate the window.
final class HostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The size of the drawn notch, which the panel uses to decide which clicks
/// are its own and which fall through to the menu bar below.
final class ShapeBox: ObservableObject {
    @Published var size: CGSize = .zero
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = NotchModel()
    let shape = ShapeBox()
    var panel: Panel!
    var geometry: NotchGeometry!
    var monitors: [Any] = []
    var leaveWork: DispatchWorkItem?

    static let panelSize = CGSize(width: 640, height: 560)

    func applicationDidFinishLaunching(_ note: Notification) {
        guard let screen = NotchGeometry.screen() else { return }
        geometry = NotchGeometry(screen)

        panel = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = HostingView(rootView: root())
        place()
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.place() }
        }
        let track: (NSEvent) -> Void = { [weak self] _ in Task { @MainActor in self?.mouseMoved() } }
        let kinds: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseUp]
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: kinds, handler: track) as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: kinds) { track($0); return $0 } as Any)

        model.start()

        // build.sh --install passes this so installing also adds the login item.
        if CommandLine.arguments.contains("--open-at-login"), SMAppService.mainApp.status != .enabled {
            try? SMAppService.mainApp.register()
        }
    }

    func applicationWillTerminate(_ note: Notification) { model.stop() }

    func root() -> some View {
        NotchView(geometry: geometry, menu: { [weak self] in self?.menuItems() ?? [] })
            .environmentObject(model)
            .environmentObject(shape)
            .frame(width: Self.panelSize.width, height: Self.panelSize.height, alignment: .top)
    }

    func place() {
        guard let screen = NotchGeometry.screen() else { return }
        let g = NotchGeometry(screen)
        if g != geometry {
            geometry = g
            panel.contentView = HostingView(rootView: root())
        }
        let s = Self.panelSize
        panel.setFrame(NSRect(x: screen.frame.midX - s.width / 2, y: screen.frame.maxY - s.height, width: s.width, height: s.height), display: true)
    }

    /// The drawn notch in screen coordinates.
    func shapeRect() -> NSRect {
        let f = panel.frame
        let s = shape.size == .zero ? CGSize(width: geometry.width, height: geometry.height) : shape.size
        return NSRect(x: f.midX - s.width / 2, y: f.maxY - s.height, width: s.width, height: s.height)
    }

    func mouseMoved() {
        let p = NSEvent.mouseLocation
        let inside = shapeRect().insetBy(dx: -6, dy: -2).contains(p)
        panel.ignoresMouseEvents = !inside
        if inside {
            leaveWork?.cancel()
            leaveWork = nil
            if !model.hovering {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { model.hovering = true }
            }
        } else if model.hovering, leaveWork == nil {
            let w = DispatchWorkItem { [weak self] in
                guard let self else { return }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { self.model.hovering = false }
                self.leaveWork = nil
            }
            leaveWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
        }
    }

    func menuItems() -> [MenuItem] {
        let login = SMAppService.mainApp.status == .enabled
        return [
            MenuItem(title: "Refresh") { [weak self] in self?.model.refresh() },
            MenuItem(title: login ? "Don't Open at Login" : "Open at Login") {
                try? login ? SMAppService.mainApp.unregister() : SMAppService.mainApp.register()
            },
            MenuItem(title: "Quit RexNotch") { NSApp.terminate(nil) },
        ]
    }
}

struct MenuItem: Identifiable {
    let title: String
    let action: () -> Void
    var id: String { title }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
