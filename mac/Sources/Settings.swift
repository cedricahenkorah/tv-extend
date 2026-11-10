import Foundation
import ServiceManagement

/// How big things look on the TV. The video sent to the TV is always 1920×1080; the
/// HiDPI sizes render at 2× and are scaled to fit, so text is larger and stays crisp.
enum DisplaySize: String, CaseIterable {
    case standard
    case larger
    case largest

    var title: String {
        switch self {
        case .standard: "Default (1920 × 1080)"
        case .larger: "Larger Text (looks like 1280 × 720)"
        case .largest: "Largest Text (looks like 960 × 540)"
        }
    }

    /// Layout size macOS uses ("looks like").
    var points: (width: Int, height: Int) {
        switch self {
        case .standard: (1920, 1080)
        case .larger: (1280, 720)
        case .largest: (960, 540)
        }
    }

    var hiDPI: Bool { self != .standard }
}

/// Persisted user settings (UserDefaults).
struct Settings {
    private static let defaults = UserDefaults.standard

    /// Size of the video sent to the TV.
    static let streamWidth = 1920
    static let streamHeight = 1080
    static let fps = 60
    static let bitrateChoices = [10, 20, 30] // Mbps

    static var displaySize: DisplaySize {
        get { DisplaySize(rawValue: defaults.string(forKey: "displaySize") ?? "") ?? .standard }
        set { defaults.set(newValue.rawValue, forKey: "displaySize") }
    }

    static var bitrateMbps: Int {
        get { defaults.object(forKey: "bitrateMbps") as? Int ?? 20 }
        set { defaults.set(newValue, forKey: "bitrateMbps") }
    }

    /// Connect to the last-used TV whenever it shows up on the network.
    static var autoConnect: Bool {
        get { defaults.object(forKey: "autoConnect") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "autoConnect") }
    }

    static var saveDebugRecording: Bool {
        get { defaults.bool(forKey: "saveDebugRecording") }
        set { defaults.set(newValue, forKey: "saveDebugRecording") }
    }

    /// Bonjour service name of the last TV connected to (for auto-connect).
    static var lastServiceName: String? {
        get { defaults.string(forKey: "lastServiceName") }
        set { defaults.set(newValue, forKey: "lastServiceName") }
    }

    /// Last IP typed into "Connect by IP Address…".
    static var lastHost: String? {
        get { defaults.string(forKey: "lastTVHost") }
        set { defaults.set(newValue, forKey: "lastTVHost") }
    }

    // MARK: Launch at login (macOS manages this, not UserDefaults)

    static var launchAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static var launchAtLoginNeedsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }
}
