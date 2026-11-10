import AppKit

/// Menu-bar + Dock UI and the streaming session.
///
/// Connect flow: reach the TV first (so nothing flickers if it's unreachable), then create
/// the virtual display, capture it, encode it and send every frame to the TV.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum State: Equatable {
        case idle
        case connecting(host: String)
        case streaming(tvName: String)
        case stopping
    }

    // Stream settings. These become user settings in Phase 5.
    private let width = 1920
    private let height = 1080
    private let fps = 60
    private let bitrate = 20_000_000

    private var statusItem: NSStatusItem!
    private var state = State.idle
    private var lastMessage: String?

    // Session objects (alive while connecting/streaming).
    private var client: StreamClient?
    private var display: VirtualDisplay?
    private var capturer: ScreenCapturer?
    private var encoder: VideoEncoder?
    private var recorder: Recorder?

    // Stats.
    private var statsTimer: Timer?
    private var lastBytesSent = 0
    private var bitrateMbps = 0.0

    private let defaults = UserDefaults.standard
    private let lastHostKey = "lastTVHost"
    private let debugRecordingKey = "saveDebugRecording"

    private let recordingsDirectory = FileManager.default
        .urls(for: .moviesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("TV Extend", isDirectory: true)

    // MARK: App lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let statusMenu = NSMenu()
        statusMenu.delegate = self // rebuilt every time it opens
        statusItem.menu = statusMenu

        let appMenu = NSMenu()
        appMenu.delegate = self
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        let mainMenu = NSMenu()
        mainMenu.addItem(appItem)
        NSApp.mainMenu = mainMenu

        updateIcon()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard client != nil else { return .terminateNow }
        Task {
            await stopSession()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: Menus (status item, app menu and Dock menu share one builder)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for item in makeMenuItems() { menu.addItem(item) }
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false
        // macOS adds its own Quit to the Dock menu.
        for item in makeMenuItems(includeQuit: false) { menu.addItem(item) }
        return menu
    }

    private func makeMenuItems(includeQuit: Bool = true) -> [NSMenuItem] {
        var items: [NSMenuItem] = []

        let status = NSMenuItem(title: statusText(), action: nil, keyEquivalent: "")
        status.isEnabled = false
        items.append(status)
        if let lastMessage, state == .idle {
            let message = NSMenuItem(title: lastMessage, action: nil, keyEquivalent: "")
            message.isEnabled = false
            items.append(message)
        }
        items.append(.separator())

        let connect = item("Connect to TV…", #selector(connectToTV), "k")
        connect.isEnabled = state == .idle
        items.append(connect)

        let disconnect = item("Disconnect", #selector(disconnect), "d")
        disconnect.isEnabled = {
            if case .streaming = state { return true }
            if case .connecting = state { return true }
            return false
        }()
        items.append(disconnect)

        items.append(.separator())
        let recording = item("Save Debug Recording", #selector(toggleDebugRecording), "")
        recording.state = defaults.bool(forKey: debugRecordingKey) ? .on : .off
        items.append(recording)
        items.append(item("Show Recordings in Finder", #selector(revealRecordings), ""))

        if includeQuit {
            items.append(.separator())
            items.append(NSMenuItem(title: "Quit TV Extend", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        }
        return items
    }

    private func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func statusText() -> String {
        switch state {
        case .idle:
            return "Not connected"
        case .connecting(let host):
            return "Connecting to \(host)…"
        case .stopping:
            return "Disconnecting…"
        case .streaming(let name):
            var parts = ["Streaming to \(name)"]
            if let rtt = client?.roundTripMs { parts.append(String(format: "%.0f ms", rtt)) }
            parts.append(String(format: "%.1f Mbps", bitrateMbps))
            if let dropped = client?.framesDropped, dropped > 0 { parts.append("\(dropped) dropped") }
            return parts.joined(separator: " · ")
        }
    }

    // MARK: Actions

    @objc private func connectToTV() {
        guard state == .idle, let host = askForHost() else { return }
        defaults.set(host, forKey: lastHostKey)
        lastMessage = nil
        setState(.connecting(host: host))
        Task { await startSession(host: host) }
    }

    @objc private func disconnect() {
        guard state != .idle, state != .stopping else { return }
        Task { await stopSession() }
    }

    @objc private func toggleDebugRecording() {
        defaults.set(!defaults.bool(forKey: debugRecordingKey), forKey: debugRecordingKey)
    }

    @objc private func revealRecordings() {
        try? FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(recordingsDirectory)
    }

    private func askForHost() -> String? {
        let alert = NSAlert()
        alert.messageText = "Connect to TV"
        alert.informativeText = "Open TV Extend on the TV and enter the address it shows (the port is optional)."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "192.168.1.42"
        field.stringValue = defaults.string(forKey: lastHostKey) ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        // Accept "1.2.3.4" or "1.2.3.4:48100".
        let host = field.stringValue.trimmingCharacters(in: .whitespaces)
            .split(separator: ":").first.map(String.init) ?? ""
        return host.isEmpty ? nil : host
    }

    // MARK: Session

    private func startSession(host: String) async {
        let client = StreamClient(host: host)
        self.client = client
        client.onDisconnect = { [weak self] reason in
            Task { @MainActor in self?.connectionEnded(reason) }
        }

        do {
            let tv = try await client.connect(width: width, height: height, fps: fps)
            guard self.client === client else { return } // cancelled while connecting

            let display = try VirtualDisplay(name: tv.name, width: width, height: height, refreshRate: Double(fps))
            let encoder = try VideoEncoder(width: width, height: height, fps: fps, bitrate: bitrate)
            let capturer = ScreenCapturer()
            let recorder = defaults.bool(forKey: debugRecordingKey) ? try Recorder(directory: recordingsDirectory) : nil

            encoder.onFrame = { frame in
                client.send(frame)
                recorder?.write(frame)
            }
            capturer.onFrame = { pixelBuffer, pts in encoder.encode(pixelBuffer, pts: pts) }
            capturer.onError = { [weak self] error in
                Task { @MainActor in self?.connectionEnded("Capture stopped: \(error.localizedDescription)") }
            }
            client.onKeyframeRequest = { [weak encoder, weak capturer] in
                encoder?.requestKeyframe()
                capturer?.resendLastFrame() // in case the screen is idle
            }

            self.display = display
            self.encoder = encoder
            self.capturer = capturer
            self.recorder = recorder

            try await capturer.start(displayID: display.displayID, width: width, height: height, fps: fps)
            setState(.streaming(tvName: tv.name))
        } catch {
            guard self.client === client else { return } // user pressed Disconnect; no error to show
            await stopSession()
            showError(error)
        }
    }

    private func stopSession() async {
        guard state != .stopping else { return }
        setState(.stopping)

        let client = self.client
        self.client = nil
        client?.onDisconnect = nil

        await capturer?.stop()
        capturer?.onFrame = nil
        encoder?.invalidate()
        encoder?.onFrame = nil
        await recorder?.finish()
        client?.disconnect()

        capturer = nil
        encoder = nil
        recorder = nil
        display = nil // removes the virtual display
        setState(.idle)
    }

    /// The TV went away (or capture failed) without the user asking.
    private func connectionEnded(_ reason: String) {
        guard client != nil, state != .stopping else { return }
        lastMessage = reason
        Task { await stopSession() }
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "TV Extend couldn't connect"
        var text = error.localizedDescription
        if error is StreamError == false {
            text += "\n\nIf this is the first run, allow TV Extend under System Settings → Privacy & Security → "
                + "Screen & System Audio Recording, then quit and reopen the app."
        }
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: UI state

    private func setState(_ newState: State) {
        state = newState
        statsTimer?.invalidate()
        statsTimer = nil

        if case .streaming = newState {
            lastBytesSent = 0
            bitrateMbps = 0
            statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refreshStats() }
            }
        }
        updateIcon()
    }

    private func refreshStats() {
        guard let client else { return }
        let bytes = client.bytesSent
        bitrateMbps = Double(bytes - lastBytesSent) * 8 / 1_000_000
        lastBytesSent = bytes
        statusItem.button?.toolTip = statusText()
    }

    private func updateIcon() {
        let streaming: Bool = { if case .streaming = state { return true } else { return false } }()
        statusItem.button?.image = NSImage(
            systemSymbolName: streaming ? "tv.fill" : "tv",
            accessibilityDescription: "TV Extend"
        )
        statusItem.button?.toolTip = statusText()
    }
}
