import AppKit
import Network
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: AgentStore!
    private var settings: SettingsStore!
    private var updater: Updater!
    private var panelController: NotchPanelController?
    private var settingsWindow: SettingsWindowController?
    private var statusItem: NSStatusItem?
    /// Hidden until an update is worth mentioning.
    private var updateItem: NSMenuItem?
    private var statusItemBadged = false
    private let networkMonitor = NWPathMonitor()
    private let networkMonitorQueue = DispatchQueue(
        label: "gg.t3tools.t3notch.network-monitor"
    )
    private var networkWasSatisfied = true
    private var remoteRefreshTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        settings = SettingsStore()
        store = AgentStore(settings: settings)
        updater = Updater(settings: settings)
        let controller = NotchPanelController(store: store)
        panelController = controller
        settingsWindow = SettingsWindowController(
            store: store,
            settings: settings,
            updater: updater
        )

        // Applied immediately rather than on the next poll, so a flipped switch
        // feels like it did something.
        settings.onChange = { [weak self] in
            self?.store.applySettings()
            self?.updater.applySettings()
            self?.panelController?.refresh()
        }

        controller.start()
        installStatusItem()
        installMainMenu()
        store.bootstrap()
        startConnectivityObservers()
        if settings.values.automaticUpdates {
            updater.start()
        }

        if settings.values.needsQuickStart {
            // After bootstrap, so the connection test has a chance to pass on a
            // machine that is already set up.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                settingsWindow?.show(quickStart: true)
            }
        }

        // The window frame is fixed; this only re-syncs hit-testing after the
        // store flips presentation on its own (attention, completion, etc).
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.panelController?.refresh()
                self?.syncStatusItemBadge()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        networkMonitor.cancel()
        remoteRefreshTimer?.invalidate()
        remoteRefreshTimer = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private func startConnectivityObservers() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(macDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        networkMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let isSatisfied = path.status == .satisfied
                if isSatisfied && !self.networkWasSatisfied {
                    self.store.handleConnectivityRestored()
                }
                self.networkWasSatisfied = isSatisfied
            }
        }
        networkMonitor.start(queue: networkMonitorQueue)
        remoteRefreshTimer = Timer.scheduledTimer(
            withTimeInterval: 60,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.store.performRemoteMaintenance()
            }
        }
    }

    @objc private func macDidWake() {
        store.handleConnectivityRestored()
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = Self.statusItemImage()
        }
        let menu = NSMenu()
        menu.delegate = self
        updateItem = NSMenuItem(
            title: "Install Update",
            action: #selector(installUpdate),
            keyEquivalent: ""
        )
        updateItem?.isHidden = true
        menu.addItem(updateItem!)
        menu.addItem(NSMenuItem(title: "Expand Notch", action: #selector(expand), keyEquivalent: "e"))
        menu.addItem(
            NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        )
        menu.addItem(
            NSMenuItem(title: "Quick Start…", action: #selector(openQuickStart), keyEquivalent: "")
        )
        menu.addItem(
            NSMenuItem(
                title: "Check for Updates…",
                action: #selector(checkForUpdates),
                keyEquivalent: ""
            )
        )
        menu.addItem(NSMenuItem(title: "Reconnect", action: #selector(reconnect), keyEquivalent: "r"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit T3Notch", action: #selector(quit), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    /// The menu bar shown while a window is open and the app is briefly a regular
    /// one. Without it that bar would be empty, and the shortcuts a window needs —
    /// ⌘C on the selectable diagnostics, ⌘W, ⌘Q — would do nothing.
    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "About T3Notch",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Hide T3Notch",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        appMenu.addItem(
            withTitle: "Quit T3Notch",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appItem.submenu = appMenu
        main.addItem(appItem)

        // Standard editing actions travel the responder chain, so they are wired by
        // selector name rather than to any particular object.
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        let editActions: [(title: String, selector: String, key: String, shift: Bool)] = [
            ("Undo", "undo:", "z", false),
            ("Redo", "redo:", "z", true),
            ("Cut", "cut:", "x", false),
            ("Copy", "copy:", "c", false),
            ("Paste", "paste:", "v", false),
            ("Select All", "selectAll:", "a", false),
        ]
        for action in editActions {
            if action.title == "Cut" { editMenu.addItem(.separator()) }
            let item = NSMenuItem(
                title: action.title,
                action: NSSelectorFromString(action.selector),
                keyEquivalent: action.key
            )
            if action.shift {
                item.keyEquivalentModifierMask = [.command, .shift]
            }
            editMenu.addItem(item)
        }
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(
            withTitle: "Close",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        windowMenu.addItem(
            withTitle: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }

    /// Menu bar glyph: the panel's own silhouette, drawn as a template image so
    /// it tints itself for light, dark, and highlighted menu bars.
    ///
    /// A waiting update adds a dot beside it. The image is a template, so the dot
    /// cannot be blue — being detached from the silhouette is what makes it read
    /// as a badge rather than part of the shape.
    private static func statusItemImage(badged: Bool = false) -> NSImage {
        let notch = NSSize(width: 20, height: 11)
        let dot: CGFloat = 4
        let gap: CGFloat = 3
        let size = NSSize(
            width: badged ? notch.width + gap + dot : notch.width,
            height: notch.height
        )
        // `flipped: true` keeps NotchShape's top-down geometry pointing down.
        let image = NSImage(size: size, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setFillColor(NSColor.black.cgColor)
            let path = NotchShape(topRadius: 3, bottomRadius: 4.5)
                .path(in: CGRect(origin: .zero, size: notch))
            context.addPath(path.cgPath)
            context.fillPath()
            if badged {
                context.fillEllipse(
                    in: CGRect(
                        x: notch.width + gap,
                        y: (notch.height - dot) / 2,
                        width: dot,
                        height: dot
                    )
                )
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = badged ? "T3Notch, update available" : "T3Notch"
        return image
    }

    /// Cheap enough to run on the panel's own tick, and only redraws on a change.
    private func syncStatusItemBadge() {
        guard updater.hasOffer != statusItemBadged else { return }
        statusItemBadged = updater.hasOffer
        statusItem?.button?.image = Self.statusItemImage(badged: statusItemBadged)
    }

    @objc private func expand() {
        store.expand()
        panelController?.refresh()
    }

    @objc private func openSettings() {
        settingsWindow?.show()
    }

    @objc private func openQuickStart() {
        settingsWindow?.show(quickStart: true)
    }

    /// Opens the panel where the result will show up, then asks GitHub.
    @objc private func checkForUpdates() {
        settingsWindow?.show()
        Task { await updater.check() }
    }

    @objc private func installUpdate() {
        switch updater.status {
        case .readyToInstall:
            updater.install()
        case let .available(release):
            settingsWindow?.show()
            updater.download(release)
        default:
            checkForUpdates()
        }
    }

    @objc private func reconnect() {
        store.handleConnectivityRestored()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

extension AppDelegate: NSMenuDelegate {
    /// The update entry is written the moment the menu opens, so it never shows a
    /// version that has since been installed or withdrawn.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let updateItem else { return }
        switch updater.status {
        case let .readyToInstall(release, _):
            updateItem.title = "Install \(release.version) and Relaunch"
            updateItem.isHidden = false
        case let .available(release):
            updateItem.title = "Download \(release.version)"
            updateItem.isHidden = false
        default:
            updateItem.isHidden = true
        }
    }
}
