import CoreGraphics
import Foundation

enum VirtualDisplayError: LocalizedError {
    case createFailed
    case applySettingsFailed

    var errorDescription: String? {
        switch self {
        case .createFailed: "macOS refused to create the virtual display."
        case .applySettingsFailed: "macOS rejected the virtual display's resolution settings."
        }
    }
}

/// A virtual monitor that macOS treats like a real one.
/// The display exists for as long as this object is alive.
///
/// `width`/`height` are the size macOS lays things out at ("looks like"). With `hiDPI`,
/// the display renders at 2× that in pixels, like a Retina screen.
final class VirtualDisplay {
    let displayID: CGDirectDisplayID
    let width: Int
    let height: Int
    let hiDPI: Bool

    // Releasing this removes the display from macOS.
    private let display: CGVirtualDisplay

    init(name: String, width: Int, height: Int, refreshRate: Double, hiDPI: Bool = false) throws {
        let scale = hiDPI ? 2 : 1
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.queue = DispatchQueue.main
        descriptor.name = name
        descriptor.maxPixelsWide = UInt32(width * scale)
        descriptor.maxPixelsHigh = UInt32(height * scale)
        // Physical size of a ~55" 16:9 TV. macOS uses this to compute DPI.
        descriptor.sizeInMillimeters = CGSize(width: 1210, height: 680)
        descriptor.vendorID = 0x7458 // "tX"
        descriptor.productID = 0x0001
        descriptor.serialNum = 0x0001
        descriptor.terminationHandler = { _, _ in
            NSLog("[display] virtual display terminated by the system")
        }

        guard let display = CGVirtualDisplay(descriptor: descriptor), display.displayID != 0 else {
            throw VirtualDisplayError.createFailed
        }

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = hiDPI ? 1 : 0
        settings.modes = [
            CGVirtualDisplayMode(width: UInt(width), height: UInt(height), refreshRate: refreshRate),
        ]
        guard display.applySettings(settings) else {
            throw VirtualDisplayError.applySettingsFailed
        }

        self.display = display
        self.displayID = display.displayID
        self.width = width
        self.height = height
        self.hiDPI = hiDPI
        NSLog("[display] created virtual display %u (looks like %dx%d%@ @ %.0f Hz)",
              displayID, width, height, hiDPI ? ", HiDPI" : "", refreshRate)
    }

    /// macOS picks its own default mode for a new display (for HiDPI it chooses the full
    /// pixel size at 1×). Switch to the one we asked for: "looks like" width×height at our scale.
    func activateMode() async {
        let scale = hiDPI ? 2 : 1
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        func isWanted(_ mode: CGDisplayMode) -> Bool {
            mode.width == width && mode.height == height
                && mode.pixelWidth == width * scale && mode.pixelHeight == height * scale
        }

        for _ in 0..<30 {
            if let current = CGDisplayCopyDisplayMode(displayID), isWanted(current) { return }
            let modes = (CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode]) ?? []
            if let mode = modes.first(where: isWanted) {
                var config: CGDisplayConfigRef?
                CGBeginDisplayConfiguration(&config)
                CGConfigureDisplayWithDisplayMode(config, displayID, mode, nil)
                let error = CGCompleteDisplayConfiguration(config, .forSession)
                NSLog("[display] switched to %dx%d @ %dx%d px (result %d)",
                      mode.width, mode.height, mode.pixelWidth, mode.pixelHeight, error.rawValue)
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        NSLog("[display] couldn't switch to %dx%d at %dx scale", width, height, scale)
    }

    deinit {
        NSLog("[display] removing virtual display %u", displayID)
    }
}
