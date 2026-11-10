import CoreMedia
import Foundation
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case displayNotFound

    var errorDescription: String? {
        switch self {
        case .displayNotFound: "The virtual display never appeared in ScreenCaptureKit."
        }
    }
}

/// Captures one display with ScreenCaptureKit and hands out NV12 pixel buffers.
/// Frames only arrive when something on the display changes.
final class ScreenCapturer: NSObject, SCStreamOutput, SCStreamDelegate {
    /// Called on the capture queue for every new frame.
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    var onError: ((Error) -> Void)?

    let queue = DispatchQueue(label: "tvextend.capture", qos: .userInteractive)
    private var stream: SCStream?
    /// The most recent frame (capture-queue confined), so a keyframe can be produced
    /// even when nothing on screen is changing.
    private var lastFrame: CVPixelBuffer?

    func start(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int) async throws {
        let display = try await findDisplay(displayID)

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange // NV12, what the encoder wants
        config.showsCursor = true
        config.queueDepth = 5 // we hold on to one buffer (lastFrame)

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        NSLog("[capture] started on display %u", displayID)
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
        queue.sync { lastFrame = nil }
        NSLog("[capture] stopped")
    }

    /// Re-deliver the last frame with a fresh timestamp (used to answer keyframe requests
    /// while the screen is idle and ScreenCaptureKit isn't producing new frames).
    func resendLastFrame() {
        queue.async { [self] in
            guard let lastFrame else { return }
            onFrame?(lastFrame, CMClockGetTime(CMClockGetHostTimeClock()))
        }
    }

    /// A freshly created display can take a moment to show up in ScreenCaptureKit.
    private func findDisplay(_ displayID: CGDirectDisplayID) async throws -> SCDisplay {
        for _ in 0..<20 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            if let display = content.displays.first(where: { $0.displayID == displayID }) {
                return display
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw CaptureError.displayNotFound
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer
        else { return }

        lastFrame = pixelBuffer
        onFrame?(pixelBuffer, sampleBuffer.presentationTimeStamp)
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("[capture] stream stopped with error: %@", error.localizedDescription)
        onError?(error)
    }
}
