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
final class VirtualDisplay {
    let displayID: CGDirectDisplayID
    let width: Int
    let height: Int

    // Releasing this removes the display from macOS.
    private let display: CGVirtualDisplay

    init(name: String, width: Int, height: Int, refreshRate: Double) throws {
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.queue = DispatchQueue.main
        descriptor.name = name
        descriptor.maxPixelsWide = UInt32(width)
        descriptor.maxPixelsHigh = UInt32(height)
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
        settings.hiDPI = 0
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
        NSLog("[display] created virtual display %u (%dx%d @ %.0f Hz)", displayID, width, height, refreshRate)
    }

    deinit {
        NSLog("[display] removing virtual display %u", displayID)
    }
}
