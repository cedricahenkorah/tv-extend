import CoreMedia
import Foundation
import VideoToolbox

enum EncoderError: LocalizedError {
    case createFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .createFailed(let status): "Could not create the H.264 encoder (error \(status))."
        }
    }
}

struct EncodedFrame {
    /// SPS + PPS in Annex B form. Only set on keyframes.
    let codecConfig: Data?
    /// The frame's NAL units in Annex B form (start codes, no length prefixes).
    let data: Data
    let isKeyframe: Bool
    let pts: CMTime
    /// The encoder's original output (AVCC), used for writing a .mov.
    let sampleBuffer: CMSampleBuffer
}

/// Hardware H.264 encoder tuned for low latency: real-time, no B-frames,
/// one frame in → one frame out.
final class VideoEncoder {
    /// Called on a VideoToolbox thread, in encode order.
    var onFrame: ((EncodedFrame) -> Void)?

    private var session: VTCompressionSession?
    private let lock = NSLock()
    private var keyframeRequested = true

    private static let startCode: [UInt8] = [0, 0, 0, 1]

    init(width: Int, height: Int, fps: Int, bitrate: Int) throws {
        let spec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
        ]
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: spec as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        guard status == noErr, let session else { throw EncoderError.createFailed(status) }
        self.session = session

        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_ConstrainedHigh_AutoLevel)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_AverageBitRate, bitrate as CFNumber)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, fps as CFNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, (fps * 2) as CFNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 2 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(session)
        NSLog("[encoder] H.264 %dx%d @ %d fps, %d Mbps", width, height, fps, bitrate / 1_000_000)
    }

    deinit {
        invalidate()
    }

    /// Ask for the next frame to be a keyframe (e.g. when a TV connects).
    func requestKeyframe() {
        lock.lock()
        keyframeRequested = true
        lock.unlock()
    }

    func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        guard let session else { return }

        lock.lock()
        let forceKeyframe = keyframeRequested
        keyframeRequested = false
        lock.unlock()

        let properties: CFDictionary? = forceKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
            : nil

        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: properties,
            infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer, let self else {
                if status != noErr { NSLog("[encoder] encode failed: %d", status) }
                return
            }
            self.handle(sampleBuffer)
        }
    }

    /// Flush pending frames and shut the encoder down.
    func invalidate() {
        guard let session else { return }
        self.session = nil
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
    }

    // MARK: Private

    private func set(_ key: CFString, _ value: CFTypeRef) {
        guard let session else { return }
        let status = VTSessionSetProperty(session, key: key, value: value)
        if status != noErr {
            NSLog("[encoder] could not set %@ (error %d)", key as String, status)
        }
    }

    private func handle(_ sampleBuffer: CMSampleBuffer) {
        guard let block = sampleBuffer.dataBuffer, let format = sampleBuffer.formatDescription else { return }

        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[CFString: Any]]
        let isKeyframe = !((attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)

        // Copy the encoded bytes out (the block buffer may not be contiguous).
        var avcc = Data(count: CMBlockBufferGetDataLength(block))
        let copyStatus = avcc.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: bytes.baseAddress!)
        }
        guard copyStatus == noErr else { return }

        let lengthSize = Self.nalLengthSize(format)
        let frame = EncodedFrame(
            codecConfig: isKeyframe ? Self.parameterSets(format) : nil,
            data: Self.annexB(fromAVCC: avcc, lengthSize: lengthSize),
            isKeyframe: isKeyframe,
            pts: sampleBuffer.presentationTimeStamp,
            sampleBuffer: sampleBuffer
        )
        onFrame?(frame)
    }

    /// Replace each NAL unit's length prefix with a start code.
    private static func annexB(fromAVCC avcc: Data, lengthSize: Int) -> Data {
        var out = Data(capacity: avcc.count + 16)
        var offset = 0
        while offset + lengthSize <= avcc.count {
            var nalLength = 0
            for i in 0..<lengthSize {
                nalLength = (nalLength << 8) | Int(avcc[offset + i])
            }
            offset += lengthSize
            guard nalLength > 0, offset + nalLength <= avcc.count else { break }
            out.append(contentsOf: startCode)
            out.append(avcc[offset..<(offset + nalLength)])
            offset += nalLength
        }
        return out
    }

    private static func parameterSets(_ format: CMFormatDescription) -> Data {
        var count = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: 0, parameterSetPointerOut: nil,
            parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil
        )
        var out = Data()
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
            )
            if status == noErr, let pointer {
                out.append(contentsOf: startCode)
                out.append(pointer, count: size)
            }
        }
        return out
    }

    private static func nalLengthSize(_ format: CMFormatDescription) -> Int {
        var length: Int32 = 4
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: 0, parameterSetPointerOut: nil,
            parameterSetSizeOut: nil, parameterSetCountOut: nil, nalUnitHeaderLengthOut: &length
        )
        return Int(length)
    }
}
