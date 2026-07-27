import AppKit
import SwiftUI

@MainActor
final class NotchPanelController: NSObject {
    private let store: AgentStore
    private var panel: NotchPanel?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var screenObserver: NSObjectProtocol?

    init(store: AgentStore) {
        self.store = store
        super.init()
    }

    func start() {
        let panel = NotchPanel(store: store)
        self.panel = panel
        panel.orderFrontRegardless()
        panel.reposition()
        panel.syncInteractivity()

        installMonitors()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.panel?.reposition()
            }
        }
    }

    private func installMonitors() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) {
            [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateHover()
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) {
            [weak self] event in
            MainActor.assumeIsolated {
                self?.updateHover()
            }
            return event
        }
    }

    /// Hover is driven by a global monitor rather than a tracking area, because the
    /// collapsed panel ignores mouse events so the menu bar stays clickable.
    private func updateHover() {
        guard let panel,
            let screen = NotchGeometry.preferredScreen(named: store.settingsValues.displayName)
        else { return }
        let mouse = NSEvent.mouseLocation

        let notch = NotchGeometry.notchRect(on: screen).insetBy(dx: -30, dy: -6)
        let overNotch = notch.contains(mouse)

        let expanded = store.presentation == .expanded || store.presentation == .attention
        let overPanel = expanded && panel.interactiveFrame.contains(mouse)

        let hovering = overNotch || overPanel
        if hovering != store.isHovering {
            store.setHovering(hovering)
            if !hovering {
                store.collapseIfIdle()
            }
        }
        // Every move, not just the ones that change hover: which clicks the panel
        // may take depends on where the pointer is, so this has to keep up with it.
        panel.syncInteractivity(pointer: mouse)
    }

    func refresh() {
        // Picking another display in settings, or unplugging one, moves the panel.
        if panel?.needsMove == true {
            panel?.reposition()
        }
        panel?.syncInteractivity()
    }
}

@MainActor
final class NotchPanel: NSPanel {
    private let store: AgentStore
    private var hosting: NSHostingView<NotchRootView>!
    private var currentScreenName: String?

    /// True once the configured display is no longer the one being drawn on.
    var needsMove: Bool {
        let target = NotchGeometry.preferredScreen(named: store.settingsValues.displayName)
        return target?.localizedName != currentScreenName
    }

    init(store: AgentStore) {
        self.store = store
        super.init(
            contentRect: CGRect(x: 0, y: 0, width: 400, height: NotchGeometry.windowHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Above the menu bar, so the panel can hang over it like the real island.
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none

        let hosting = NSHostingView(rootView: NotchRootView(store: store))
        hosting.autoresizingMask = [.width, .height]
        self.hosting = hosting
        contentView = hosting
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Rect the user can actually interact with, i.e. the drawn panel rather than
    /// the whole oversized window.
    var interactiveFrame: CGRect {
        let width = min(store.panelSize.width, frame.width)
        let height = min(store.panelSize.height, frame.height)
        return CGRect(
            x: frame.midX - width / 2,
            y: frame.maxY - height,
            width: width,
            height: height
        )
    }

    /// The window keeps a fixed frame; only its position and hit-testing change.
    func reposition() {
        guard let screen = NotchGeometry.preferredScreen(named: store.settingsValues.displayName)
        else { return }
        currentScreenName = screen.localizedName
        store.notchMetrics = NotchGeometry.metrics(for: screen)
        setFrame(NotchGeometry.windowFrame(on: screen), display: true)
        syncInteractivity()
    }

    /// Only the drawn panel may take clicks.
    ///
    /// The window is deliberately far taller than what it draws, so that the panel
    /// can spring open without resizing it. Accepting events across all of it made
    /// the empty part an invisible click trap over whatever sits under the notch —
    /// the quick start window, for one, whose buttons could not be pressed.
    func syncInteractivity(pointer: CGPoint = NSEvent.mouseLocation) {
        let expanded = store.presentation == .expanded || store.presentation == .attention
        // Collapsed states must not swallow menu bar clicks either.
        let ignores = !(expanded && interactiveFrame.contains(pointer))
        // This runs on every mouse move, so don't poke the window needlessly.
        if ignoresMouseEvents != ignores {
            ignoresMouseEvents = ignores
        }
    }
}
