import CoreGraphics
import Foundation

/// The Mac half of a session: virtual display → capture → encoder.
///
/// It's kept separate from the network connection so the display can stay up while the
/// connection drops and reconnects (otherwise macOS would move all its windows back to
/// the Mac's screen every time Wi-Fi hiccups).
final class DisplaySession {
    let display: VirtualDisplay
    private let capturer: ScreenCapturer
    private let encoder: VideoEncoder
    private let recorder: Recorder?

    private let lock = NSLock()
    private var _client: StreamClient?

    /// Called on the main queue if capture stops on its own.
    var onCaptureError: ((Error) -> Void)?

    private init(display: VirtualDisplay, capturer: ScreenCapturer, encoder: VideoEncoder, recorder: Recorder?) {
        self.display = display
        self.capturer = capturer
        self.encoder = encoder
        self.recorder = recorder
    }

    static func start(name: String, size: DisplaySize, bitrateMbps: Int, recordTo directory: URL?) async throws -> DisplaySession {
        let display = try VirtualDisplay(
            name: name,
            width: size.points.width,
            height: size.points.height,
            refreshRate: Double(Settings.fps),
            hiDPI: size.hiDPI
        )
        await display.activateMode()
        let encoder = try VideoEncoder(
            width: Settings.streamWidth,
            height: Settings.streamHeight,
            fps: Settings.fps,
            bitrate: bitrateMbps * 1_000_000
        )
        let recorder = try directory.map { try Recorder(directory: $0) }
        let capturer = ScreenCapturer()
        let session = DisplaySession(display: display, capturer: capturer, encoder: encoder, recorder: recorder)

        encoder.onFrame = { [weak session] frame in
            session?.client?.send(frame)
            recorder?.write(frame)
        }
        capturer.onFrame = { pixelBuffer, pts in encoder.encode(pixelBuffer, pts: pts) }
        capturer.onError = { [weak session] error in
            DispatchQueue.main.async { session?.onCaptureError?(error) }
        }

        do {
            // Capture always produces 1920×1080; HiDPI sizes are scaled down to fit.
            try await capturer.start(
                displayID: display.displayID,
                width: Settings.streamWidth,
                height: Settings.streamHeight,
                fps: Settings.fps
            )
        } catch {
            encoder.invalidate()
            await recorder?.finish()
            throw error
        }
        return session
    }

    /// The TV currently receiving frames. Setting a new one sends it a keyframe right away.
    var client: StreamClient? {
        get { lock.withLock { _client } }
        set {
            lock.withLock { _client = newValue }
            guard let newValue else { return }
            newValue.onKeyframeRequest = { [weak self] in self?.sendKeyframe() }
            sendKeyframe()
        }
    }

    func sendKeyframe() {
        encoder.requestKeyframe()
        capturer.resendLastFrame() // in case the screen is idle
    }

    func stop() async {
        client = nil
        await capturer.stop()
        capturer.onFrame = nil
        encoder.invalidate()
        encoder.onFrame = nil
        await recorder?.finish()
    }
}
