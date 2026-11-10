import AVFoundation
import Foundation

/// Phase 1 output: writes the encoded stream to disk two ways.
/// - `.h264`: raw Annex B, exactly what we'll send to the TV (used to test the TV app in Phase 2).
/// - `.mov`: the same frames in a container QuickTime can play, so you can check the capture.
final class Recorder {
    let h264URL: URL
    let movURL: URL

    private let file: FileHandle
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var started = false
    private let lock = NSLock()
    private var _frames = 0
    private var _bytes = 0

    var frames: Int { lock.withLock { _frames } }
    var bytes: Int { lock.withLock { _bytes } }

    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "capture-\(formatter.string(from: Date()))"
        h264URL = directory.appendingPathComponent("\(name).h264")
        movURL = directory.appendingPathComponent("\(name).mov")

        FileManager.default.createFile(atPath: h264URL.path, contents: nil)
        file = try FileHandle(forWritingTo: h264URL)
    }

    /// Called on the encoder's thread.
    func write(_ frame: EncodedFrame) {
        lock.lock()
        defer { lock.unlock() }

        if !started {
            // Both files must begin with a keyframe.
            guard frame.isKeyframe else { return }
            startMovie(with: frame)
            started = true
        }

        var chunk = frame.codecConfig ?? Data()
        chunk.append(frame.data)
        file.write(chunk)

        if let input, input.isReadyForMoreMediaData {
            input.append(frame.sampleBuffer)
        }

        _frames += 1
        _bytes += chunk.count
    }

    func finish() async {
        let (writer, input) = lock.withLock { (self.writer, self.input) }

        try? file.close()
        input?.markAsFinished()
        if let writer, writer.status == .writing {
            await writer.finishWriting()
        }
        NSLog("[recorder] saved %@ and %@", h264URL.path, movURL.path)
    }

    private func startMovie(with frame: EncodedFrame) {
        do {
            let writer = try AVAssetWriter(outputURL: movURL, fileType: .mov)
            let input = AVAssetWriterInput(
                mediaType: .video,
                outputSettings: nil, // pass the H.264 frames through as-is
                sourceFormatHint: frame.sampleBuffer.formatDescription
            )
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            writer.startWriting()
            writer.startSession(atSourceTime: frame.pts)
            self.writer = writer
            self.input = input
        } catch {
            NSLog("[recorder] could not create .mov writer: %@", error.localizedDescription)
        }
    }
}
