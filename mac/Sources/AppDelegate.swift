import AppKit
import Network
import ServiceManagement

/// Menu-bar + Dock UI and the connection lifecycle.
///
/// - TVs running the TV app are discovered over Bonjour and listed by name.
/// - If the connection drops, the virtual display stays up while we reconnect (for up to
///   a minute), so windows on the TV don't jump back to the Mac.
/// - With "Connect Automatically", the last TV is connected as soon as it appears.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// Where to connect: a discovered TV, or an address typed by hand.
    private enum Target: Equatable {
        case bonjour(serviceName: String, displayName: String)
        case host(String)

        var label: String {
            switch self {
            case .bonjour(_, let name): name
            case .host(let host): host
            }
        }

        var endpoint: NWEndpoint {
            switch self {
            case .bonjour(let serviceName, _):
                .service(name: serviceName, type: TVBrowser.serviceType, domain: "local.", interface: nil)
            case .host(let host):
                .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: StreamClient.port)!)
            }
        }
    }

    private enum State: Equatable {
        case idle
        case connecting(Target)
        case streaming(Target, tvName: String)
        case reconnecting(Target, tvName: String, since: Date)
        case stopping
    }

    private static let reconnectWindow: TimeInterval = 60

    private var statusItem: NSStatusItem!
    private let browser = TVBrowser()
    private var discovered: [DiscoveredTV] = []

    private var state = State.idle
    private var lastMessage: String?
    /// Set when the user disconnects, so auto-connect doesn't immediately reconnect.
    /// Cleared when that TV leaves the network (e.g. the TV app is closed).
    private var suppressAutoConnect = false

    private var session: DisplaySession?
    private var client: StreamClient?
    private var pendingClient: StreamClient?
    private var retryTask: Task<Void, Never>?
    private var isRetrying = false

    private var statsTimer: Timer?
    private var lastBytesSent = 0
    private var bitrateMbps = 0.0

    private let recordingsDirectory = FileManager.default
        .urls(for: .moviesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("TV Extend", isDirectory: true)

    // MARK: App lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let statusMenu = NSMenu()
        statusMenu.delegate = self
        statusItem.menu = statusMenu

        let appMenu = NSMenu()
        appMenu.delegate = self
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        let mainMenu = NSMenu()
        mainMenu.addItem(appItem)
        NSApp.mainMenu = mainMenu

        browser.onChange = { [weak self] tvs in self?.discoveredTVsChanged(tvs) }
        browser.start()
        updateIcon()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard session != nil || client != nil || pendingClient != nil else { return .terminateNow }
        Task {
            await tearDown(message: nil)
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: Discovery & auto-connect

    private func discoveredTVsChanged(_ tvs: [DiscoveredTV]) {
        discovered = tvs
        let lastName = Settings.lastServiceName
        let lastTVPresent = lastName.map { name in tvs.contains { $0.serviceName == name } } ?? false

        if suppressAutoConnect && !lastTVPresent {
            suppressAutoConnect = false
        }

        switch state {
        case .idle where Settings.autoConnect && !suppressAutoConnect && lastTVPresent:
            if let tv = tvs.first(where: { $0.serviceName == lastName }) {
                connect(to: .bonjour(serviceName: tv.serviceName, displayName: tv.displayName), userInitiated: false)
            }
        case .reconnecting(.bonjour(let serviceName, _), _, _) where tvs.contains(where: { $0.serviceName == serviceName }):
            scheduleRetry(after: 0) // the TV is back; don't wait for the next retry tick
        default:
            break
        }
    }

    // MARK: Connecting

    private func connect(to target: Target, userInitiated: Bool) {
        guard state == .idle else { return }
        lastMessage = nil
        switch target {
        case .bonjour(let serviceName, _): Settings.lastServiceName = serviceName
        case .host(let host): Settings.lastHost = host
        }
        setState(.connecting(target))
        Task { await startSession(target, userInitiated: userInitiated) }
    }

    private func startSession(_ target: Target, userInitiated: Bool) async {
        do {
            let (client, tv) = try await openClient(target, timeout: 8)
            guard state == .connecting(target) else { client.disconnect(); return }

            let session = try await DisplaySession.start(
                name: tv.name,
                size: Settings.displaySize,
                bitrateMbps: Settings.bitrateMbps,
                recordTo: Settings.saveDebugRecording ? recordingsDirectory : nil
            )
            guard state == .connecting(target) else {
                await session.stop()
                client.disconnect()
                return
            }
            session.onCaptureError = { [weak self] error in
                guard let self else { return }
                Task { await self.tearDown(message: "Capture stopped: \(error.localizedDescription)") }
            }
            self.session = session
            setState(.streaming(target, tvName: tv.name))
            attach(client)
        } catch {
            guard state == .connecting(target) else { return } // user cancelled
            setState(.idle)
            if userInitiated {
                showError(error)
            } else {
                lastMessage = error.localizedDescription
            }
        }
    }

    private func openClient(_ target: Target, timeout: TimeInterval) async throws -> (StreamClient, TVInfo) {
        let client = StreamClient(endpoint: target.endpoint, label: target.label)
        pendingClient = client
        defer { if pendingClient === client { pendingClient = nil } }
        let info = try await client.connect(
            width: Settings.streamWidth, height: Settings.streamHeight, fps: Settings.fps, timeout: timeout
        )
        return (client, info)
    }

    private func attach(_ client: StreamClient) {
        self.client = client
        client.onDisconnect = { [weak self, weak client] reason in
            Task { @MainActor in
                guard let self, let client else { return }
                self.clientLost(client, reason: reason)
            }
        }
        if client.isClosed {
            clientLost(client, reason: "Connection lost.")
            return
        }
        session?.client = client
    }

    // MARK: Reconnecting

    private func clientLost(_ lost: StreamClient, reason: String) {
        guard lost === client else { return }
        client = nil
        session?.client = nil
        guard case .streaming(let target, let name) = state else { return }
        NSLog("[app] connection to %@ lost (%@); reconnecting", name, reason)
        setState(.reconnecting(target, tvName: name, since: Date()))
        scheduleRetry(after: 1)
    }

    private func scheduleRetry(after seconds: Double) {
        guard !isRetrying else { return }
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            if seconds > 0 { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            await self?.retry()
        }
    }

    private func retry() async {
        guard case .reconnecting(let target, let name, let since) = state else { return }
        if Date().timeIntervalSince(since) > Self.reconnectWindow {
            await tearDown(message: "Lost connection to \(name).")
            return
        }

        isRetrying = true
        defer { isRetrying = false }
        do {
            let (client, _) = try await openClient(target, timeout: 4)
            guard state == .reconnecting(target, tvName: name, since: since) else {
                client.disconnect()
                return
            }
            NSLog("[app] reconnected to %@", name)
            setState(.streaming(target, tvName: name))
            attach(client)
        } catch {
            guard case .reconnecting = state else { return }
            isRetrying = false
            scheduleRetry(after: 2)
        }
    }

    // MARK: Disconnecting

    private func tearDown(message: String?) async {
        guard state != .stopping else { return }
        retryTask?.cancel()
        retryTask = nil
        setState(.stopping)

        pendingClient?.disconnect()
        pendingClient = nil
        let client = self.client
        let session = self.session
        self.client = nil
        self.session = nil

        await session?.stop() // removes the virtual display
        client?.disconnect()
        lastMessage = message
        setState(.idle)
    }

    // MARK: Menus (status item, app menu and Dock menu share one builder)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for item in makeMenuItems() { menu.addItem(item) }
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        for item in makeMenuItems(includeQuit: false) { menu.addItem(item) } // macOS adds Quit
        return menu
    }

    private func makeMenuItems(includeQuit: Bool = true) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        items.append(label(statusText()))
        if let lastMessage, state == .idle { items.append(label(lastMessage)) }
        items.append(.separator())

        // TVs
        items.append(label("TVs on Your Network"))
        let currentTarget = currentTargetServiceName()
        for tv in discovered {
            let item = action(tv.displayName, #selector(connectToDiscoveredTV(_:)))
            item.representedObject = tv.serviceName
            item.indentationLevel = 1
            item.state = tv.serviceName == currentTarget ? .on : .off
            item.isEnabled = state == .idle
            items.append(item)
        }
        if discovered.isEmpty {
            let none = label("None found. Open TV Extend on your TV.")
            none.indentationLevel = 1
            items.append(none)
        }
        let byIP = action("Connect by IP Address…", #selector(connectByIP))
        byIP.isEnabled = state == .idle
        items.append(byIP)
        let disconnect = action("Disconnect", #selector(disconnect))
        disconnect.isEnabled = state != .idle && state != .stopping
        items.append(disconnect)
        items.append(.separator())

        // Settings
        items.append(submenu("Display Size", DisplaySize.allCases.map { size in
            let item = action(size.title, #selector(chooseDisplaySize(_:)))
            item.representedObject = size.rawValue
            item.state = Settings.displaySize == size ? .on : .off
            return item
        } + [.separator(), label("Applies the next time you connect")]))

        items.append(submenu("Video Quality", Settings.bitrateChoices.map { mbps in
            let suffix = mbps == 10 ? " (lighter on Wi-Fi)" : mbps == 20 ? " (default)" : " (sharpest)"
            let item = action("\(mbps) Mbps\(suffix)", #selector(chooseBitrate(_:)))
            item.representedObject = mbps
            item.state = Settings.bitrateMbps == mbps ? .on : .off
            return item
        } + [.separator(), label("Applies the next time you connect")]))

        let auto = action("Connect Automatically", #selector(toggleAutoConnect))
        auto.state = Settings.autoConnect ? .on : .off
        items.append(auto)
        let login = action("Launch at Login", #selector(toggleLaunchAtLogin))
        login.state = Settings.launchAtLogin ? .on : .off
        items.append(login)
        items.append(.separator())

        // Debugging
        let recording = action("Save Debug Recording", #selector(toggleDebugRecording))
        recording.state = Settings.saveDebugRecording ? .on : .off
        items.append(recording)
        items.append(action("Show Recordings in Finder", #selector(revealRecordings)))

        if includeQuit {
            items.append(.separator())
            items.append(NSMenuItem(title: "Quit TV Extend", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        }
        return items
    }

    private func label(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    private func submenu(_ title: String, _ children: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu()
        children.forEach(menu.addItem)
        item.submenu = menu
        return item
    }

    private func currentTargetServiceName() -> String? {
        switch state {
        case .connecting(.bonjour(let name, _)), .streaming(.bonjour(let name, _), _),
             .reconnecting(.bonjour(let name, _), _, _):
            name
        default:
            nil
        }
    }

    private func statusText() -> String {
        switch state {
        case .idle:
            return "Not connected"
        case .connecting(let target):
            return "Connecting to \(target.label)…"
        case .reconnecting(_, let name, _):
            return "Reconnecting to \(name)…"
        case .stopping:
            return "Disconnecting…"
        case .streaming(_, let name):
            var parts = ["Streaming to \(name)"]
            if let rtt = client?.roundTripMs { parts.append(String(format: "%.0f ms", rtt)) }
            parts.append(String(format: "%.1f Mbps", bitrateMbps))
            if let dropped = client?.framesDropped, dropped > 0 { parts.append("\(dropped) dropped") }
            return parts.joined(separator: " · ")
        }
    }

    // MARK: Actions

    // Menu actions can't be enabled/disabled per-state on the Dock menu reliably, so each
    // action re-checks the state.

    @objc private func connectToDiscoveredTV(_ sender: NSMenuItem) {
        guard let serviceName = sender.representedObject as? String,
              let tv = discovered.first(where: { $0.serviceName == serviceName }) else { return }
        suppressAutoConnect = false
        connect(to: .bonjour(serviceName: tv.serviceName, displayName: tv.displayName), userInitiated: true)
    }

    @objc private func connectByIP() {
        guard state == .idle, let host = askForHost() else { return }
        suppressAutoConnect = false
        connect(to: .host(host), userInitiated: true)
    }

    @objc private func disconnect() {
        guard state != .idle, state != .stopping else { return }
        suppressAutoConnect = true
        Task { await tearDown(message: nil) }
    }

    @objc private func chooseDisplaySize(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let size = DisplaySize(rawValue: raw) {
            Settings.displaySize = size
        }
    }

    @objc private func chooseBitrate(_ sender: NSMenuItem) {
        if let mbps = sender.representedObject as? Int { Settings.bitrateMbps = mbps }
    }

    @objc private func toggleAutoConnect() {
        Settings.autoConnect.toggle()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            try Settings.setLaunchAtLogin(!Settings.launchAtLogin)
            if Settings.launchAtLoginNeedsApproval {
                SMAppService.openSystemSettingsLoginItems()
            }
        } catch {
            showError(error, title: "Couldn't change Launch at Login")
        }
    }

    @objc private func toggleDebugRecording() {
        Settings.saveDebugRecording.toggle()
    }

    @objc private func revealRecordings() {
        try? FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(recordingsDirectory)
    }

    private func askForHost() -> String? {
        let alert = NSAlert()
        alert.messageText = "Connect by IP Address"
        alert.informativeText = "Enter the address shown on the TV (the port is optional)."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "192.168.1.42"
        field.stringValue = Settings.lastHost ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let host = field.stringValue.trimmingCharacters(in: .whitespaces)
            .split(separator: ":").first.map(String.init) ?? ""
        return host.isEmpty ? nil : host
    }

    private func showError(_ error: Error, title: String = "TV Extend couldn't connect") {
        let alert = NSAlert()
        alert.messageText = title
        var text = error.localizedDescription
        if !(error is StreamError) && title == "TV Extend couldn't connect" {
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
            lastBytesSent = client?.bytesSent ?? 0
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
        let symbol: String = switch state {
        case .streaming: "tv.fill"
        case .reconnecting: "tv.badge.wifi"
        default: "tv"
        }
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "TV Extend")
            ?? NSImage(systemSymbolName: "tv", accessibilityDescription: "TV Extend")
        statusItem.button?.toolTip = statusText()
    }
}
