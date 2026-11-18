import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [CGDirectDisplayID: NotchWindowController] = [:]
    private var monitors: [Any] = []
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    private let settings = AppSettings.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        rebuildNotches()
        installMouseMonitors()
        observeSystem()
        observeSettings()
        NowPlayingModel.shared.start()
        LyricsModel.shared.start()
        BatteryModel.shared.start()
        CalendarModel.shared.start()       // no-op until calendar access is granted
        settings.$bluetoothAlerts
            .receive(on: RunLoop.main)
            .sink { BluetoothModel.shared.setEnabled($0) }
            .store(in: &cancellables)
        setUpHUD()
        setUpVisualizer()
        startDevLayer()
    }

    private var eventServer: EventServer?

    /// Local event socket for Claude Code / shell hooks, plus CI polling.
    private func startDevLayer() {
        let installer = IntegrationInstaller.shared
        installer.installScripts()
        let server = EventServer(socketPath: installer.socketPath)
        server.handler = { DevRouter.handle($0) }
        do {
            try server.start()
            eventServer = server
        } catch {
            NSLog("AgentNotch: event server failed to start: \(error)")
            installer.lastError = "Event socket failed to start: \(error.localizedDescription)"
        }
        CIModel.shared.start()
    }

    /// Listen to system audio only while something plays and the visualizer is on.
    private func setUpVisualizer() {
        NowPlayingModel.shared.$isPlaying
            .combineLatest(settings.$showVisualizer)
            .map { $0 && $1 }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { AudioSpectrumModel.shared.setActive($0) }
            .store(in: &cancellables)
    }

    func applicationWillTerminate(_ notification: Notification) {
        NowPlayingModel.shared.stop()
        MediaKeyInterceptor.shared.stop()
        eventServer?.stop()
        monitors.forEach(NSEvent.removeMonitor)
        controllers.values.forEach { $0.tearDown() }
    }

    // MARK: - Notches

    private func screensToUse() -> [NSScreen] {
        let screens = NSScreen.screens
        switch settings.displayMode {
        case .allDisplays:
            return screens
        case .notchedOnly:
            let notched = screens.filter(\.hasPhysicalNotch)
            return notched.isEmpty ? Array(screens.prefix(1)) : notched
        case .mainOnly:
            return Array(screens.prefix(1)) // screens[0] is the display with the menu bar
        }
    }

    private func rebuildNotches() {
        controllers.values.forEach { $0.tearDown() }
        controllers.removeAll()
        for screen in screensToUse() {
            controllers[screen.displayID] = NotchWindowController(screen: screen) {
                SettingsWindowController.shared.show()
            }
        }
    }

    // MARK: - Mouse

    private func installMouseMonitors() {
        let moveMask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        let downMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]

        if let m = NSEvent.addGlobalMonitorForEvents(matching: moveMask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseMoved() }
        }) { monitors.append(m) }

        if let m = NSEvent.addLocalMonitorForEvents(matching: moveMask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.mouseMoved() }
            return event
        }) { monitors.append(m) }

        if let m = NSEvent.addGlobalMonitorForEvents(matching: downMask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseDown() }
        }) { monitors.append(m) }
    }

    private func mouseMoved() {
        let point = NSEvent.mouseLocation
        controllers.values.forEach { $0.handleMouseMoved(point) }
    }

    private func mouseDown() {
        let point = NSEvent.mouseLocation
        controllers.values.forEach { $0.handleMouseDown(point) }
        FileDragWatcher.mouseDown()
        watchHeldButton()
    }

    private var heldButtonTimer: Timer?

    /// Drag-and-drop sessions don't reliably reach global mouse monitors, so while the button is held
    /// (a possible file drag) the cursor is checked at 20 Hz. Stops the moment the button is released.
    private func watchHeldButton() {
        guard heldButtonTimer == nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                if NSEvent.pressedMouseButtons & 1 == 0 {
                    timer.invalidate()
                    self.heldButtonTimer = nil
                }
                self.mouseMoved()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        heldButtonTimer = timer
    }

    // MARK: - System events

    private func observeSystem() {
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildNotches() }
            .store(in: &cancellables)

        let workspace = NSWorkspace.shared.notificationCenter
        Publishers.Merge(
            workspace.publisher(for: NSWorkspace.activeSpaceDidChangeNotification),
            workspace.publisher(for: NSWorkspace.didActivateApplicationNotification)
        )
        .sink { [weak self] _ in
            self?.updateFullscreen()
            // Fullscreen transitions animate; check again once they settle.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                MainActor.assumeIsolated { self?.updateFullscreen() }
            }
        }
        .store(in: &cancellables)
    }

    private func updateFullscreen() {
        controllers.values.forEach { $0.updateFullscreenVisibility() }
    }

    private func observeSettings() {
        settings.$displayMode
            .dropFirst()
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildNotches() }
            .store(in: &cancellables)

        settings.$hideInFullscreen
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateFullscreen() }
            .store(in: &cancellables)

        settings.$showMenuBarIcon
            .receive(on: RunLoop.main)
            .sink { [weak self] show in self?.setStatusItemVisible(show) }
            .store(in: &cancellables)
    }

    // MARK: - HUD

    private func setUpHUD() {
        // Volume changes from anywhere (Control Center, other apps) show the notch HUD too,
        // but only while we're replacing the system HUD; otherwise macOS shows its own.
        VolumeController.shared.onChange = { volume, muted in
            guard AppSettings.shared.replaceSystemHUD, MediaKeyInterceptor.shared.isRunning else { return }
            HUDModel.shared.show(HUDState(kind: .volume, value: volume, muted: muted))
        }

        settings.$replaceSystemHUD
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { enabled in
                if enabled {
                    if !MediaKeyInterceptor.isTrusted { MediaKeyInterceptor.requestTrust() }
                    MediaKeyInterceptor.shared.start()
                } else {
                    MediaKeyInterceptor.shared.stop()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Menu bar icon

    private func setStatusItemVisible(_ visible: Bool) {
        if !visible {
            if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
            statusItem = nil
            return
        }
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let image = NSImage(systemSymbolName: "menubar.rectangle", accessibilityDescription: "AgentNotch") {
            image.isTemplate = true
            item.button?.image = image
        } else {
            item.button?.title = "AN"
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit AgentNotch", action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = menu
        statusItem = item
    }

    @objc private func openSettings() { SettingsWindowController.shared.show() }
    @objc private func quit() { NSApp.terminate(nil) }
}
