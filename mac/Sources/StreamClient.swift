import Foundation
import Network

/// What the TV says about itself in HELLO_ACK.
struct TVInfo: Decodable {
    let version: Int
    let name: String
    let maxWidth: Int
    let maxHeight: Int
    let codecs: [String]
}

enum StreamError: LocalizedError {
    case unreachable(String)
    case rejected
    case badMessage
    case closed(String)

    var errorDescription: String? {
        switch self {
        case .unreachable(let host):
            "Couldn't reach the TV at \(host). Check that the TV Extend app is open on the TV, and that "
                + "this Mac app is allowed under System Settings → Privacy & Security → Local Network."
        case .rejected: "The TV app rejected the connection. Make sure both apps are up to date."
        case .badMessage: "The TV sent something unexpected."
        case .closed(let reason): reason
        }
    }
}

/// TCP connection to the TV app, speaking the protocol in protocol.md.
///
/// All state lives on `queue`. Frames can be handed in from any thread; if the network
/// falls behind, delta frames are dropped and a keyframe is requested instead of letting
/// a backlog (= latency) build up.
final class StreamClient {
    static let port: UInt16 = 48100

    private enum MessageType: UInt8 {
        case hello = 0x01
        case helloAck = 0x02
        case codecConfig = 0x10
        case frame = 0x11
        case requestKeyframe = 0x20
        case ping = 0x30
        case pong = 0x31
        case bye = 0x7F
    }

    private struct Message {
        let type: UInt8
        let flags: UInt8
        let timestampUs: UInt64
        let payload: Data
    }

    private static let magic: UInt16 = 0x5458
    private static let headerSize = 16
    private static let flagKeyframe: UInt8 = 0x01
    /// Frames allowed to be waiting in the send queue before we start dropping.
    private static let maxPendingFrames = 4

    /// Called on the network queue when the TV needs a fresh keyframe.
    var onKeyframeRequest: (() -> Void)?
    /// Called once, on the network queue, when the connection ends for any reason.
    var onDisconnect: ((String) -> Void)?

    let host: String
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "tvextend.network", qos: .userInteractive)

    // Queue-confined state.
    private var closed = false
    private var pendingFrames = 0
    private var needKeyframe = false
    private var keyframeAsked = false
    private var pingTimer: DispatchSourceTimer?
    private var lastPongAt = DispatchTime.now()

    // Stats, read from the main thread.
    private let statsLock = NSLock()
    private var _bytesSent = 0
    private var _framesDropped = 0
    private var _roundTripMs: Double?

    var bytesSent: Int { statsLock.withLock { _bytesSent } }
    var framesDropped: Int { statsLock.withLock { _framesDropped } }
    var roundTripMs: Double? { statsLock.withLock { _roundTripMs } }

    init(host: String) {
        self.host = host
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.serviceClass = .interactiveVideo
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: Self.port)!,
            using: parameters
        )
    }

    // MARK: Connecting

    /// Opens the connection and does the HELLO handshake.
    func connect(width: Int, height: Int, fps: Int) async throws -> TVInfo {
        try await waitUntilReady(timeout: 8)

        let hello = try JSONSerialization.data(withJSONObject: [
            "version": 1, "codec": "avc", "width": width, "height": height, "fps": fps,
        ])
        queue.async { self.sendMessage(.hello, payload: hello) }

        let reply = try await nextMessage()
        guard reply.type == MessageType.helloAck.rawValue else { throw StreamError.rejected }
        let info = try JSONDecoder().decode(TVInfo.self, from: reply.payload)

        queue.async {
            self.receiveLoop()
            self.startPings()
        }
        return info
    }

    private func waitUntilReady(timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var finished = false
            let finish: (Error?) -> Void = { error in
                guard !finished else { return }
                finished = true
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }

            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    finish(nil)
                    // From now on, a failure means the connection dropped.
                    self?.connection.stateUpdateHandler = { state in
                        switch state {
                        case .failed(let error): self?.close(reason: "Connection lost: \(error.localizedDescription)")
                        case .cancelled: self?.close(reason: "Disconnected.")
                        default: break
                        }
                    }
                case .failed:
                    finish(StreamError.unreachable(self?.host ?? "?"))
                case .cancelled:
                    finish(StreamError.closed("Cancelled."))
                default:
                    break // .waiting (e.g. Local Network permission prompt) keeps waiting until the timeout
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard !finished else { return }
                self?.connection.cancel()
                finish(StreamError.unreachable(self?.host ?? "?"))
            }
            connection.start(queue: queue)
        }
    }

    // MARK: Sending

    /// Send one encoded frame (any thread).
    func send(_ frame: EncodedFrame) {
        queue.async { [self] in
            guard !closed else { return }

            if needKeyframe {
                if frame.isKeyframe && pendingFrames <= Self.maxPendingFrames {
                    needKeyframe = false
                    keyframeAsked = false
                } else {
                    // Can't send deltas until the TV has a keyframe to build on.
                    if !keyframeAsked && pendingFrames <= Self.maxPendingFrames {
                        keyframeAsked = true
                        onKeyframeRequest?()
                    }
                    countDrop()
                    return
                }
            }

            if pendingFrames > Self.maxPendingFrames {
                // Network is behind: drop instead of queueing more latency.
                needKeyframe = true
                keyframeAsked = false
                countDrop()
                return
            }

            let timestamp = UInt64(max(0, frame.pts.seconds) * 1_000_000)
            if let config = frame.codecConfig {
                sendMessage(.codecConfig, timestampUs: timestamp, payload: config)
            }
            sendMessage(.frame, flags: frame.isKeyframe ? Self.flagKeyframe : 0,
                        timestampUs: timestamp, payload: frame.data, isFrame: true)
        }
    }

    /// Say goodbye and close (any thread).
    func disconnect() {
        queue.async { [self] in
            guard !closed else { return }
            sendMessage(.bye)
            close(reason: "Disconnected.")
        }
    }

    // MARK: Queue-confined internals

    private func sendMessage(_ type: MessageType, flags: UInt8 = 0, timestampUs: UInt64 = 0,
                             payload: Data = Data(), isFrame: Bool = false) {
        var message = Data(capacity: Self.headerSize + payload.count)
        message.appendBigEndian(Self.magic)
        message.append(type.rawValue)
        message.append(flags)
        message.appendBigEndian(UInt32(payload.count))
        message.appendBigEndian(timestampUs)
        message.append(payload)

        if isFrame { pendingFrames += 1 }
        connection.send(content: message, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if isFrame { self.pendingFrames -= 1 }
            if let error { self.close(reason: "Send failed: \(error.localizedDescription)") }
        })
        statsLock.withLock { _bytesSent += message.count }
    }

    private func receiveLoop() {
        receiveMessage { [weak self] result in
            guard let self, !self.closed else { return }
            switch result {
            case .failure(let error):
                self.close(reason: (error as? StreamError)?.errorDescription ?? "Connection lost: \(error.localizedDescription)")
            case .success(let message):
                switch MessageType(rawValue: message.type) {
                case .requestKeyframe:
                    self.onKeyframeRequest?()
                case .pong:
                    self.lastPongAt = .now()
                    let rtt = Double(Self.nowUs() &- message.timestampUs) / 1000
                    self.statsLock.withLock { self._roundTripMs = rtt }
                case .ping:
                    self.sendMessage(.pong, timestampUs: message.timestampUs)
                case .bye:
                    self.close(reason: "The TV closed the connection.")
                    return
                default:
                    break
                }
                self.receiveLoop()
            }
        }
    }

    private func startPings() {
        lastPongAt = .now()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, !self.closed else { return }
            if DispatchTime.now().uptimeNanoseconds - self.lastPongAt.uptimeNanoseconds > 5_000_000_000 {
                self.close(reason: "The TV stopped responding.")
                return
            }
            self.sendMessage(.ping, timestampUs: Self.nowUs())
        }
        timer.resume()
        pingTimer = timer
    }

    /// Every caller runs on `queue` (Network.framework callbacks are delivered there too).
    private func close(reason: String) {
        guard !closed else { return }
        closed = true
        pingTimer?.cancel()
        pingTimer = nil
        // Keep stateUpdateHandler: if we're still connecting, .cancelled unblocks waitUntilReady.
        connection.cancel()
        NSLog("[network] closed: %@", reason)
        onDisconnect?(reason)
        onDisconnect = nil
        onKeyframeRequest = nil
    }

    private func countDrop() {
        statsLock.withLock { _framesDropped += 1 }
    }

    // MARK: Receiving

    private func nextMessage() async throws -> Message {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.receiveMessage { continuation.resume(with: $0) }
            }
        }
    }

    private func receiveMessage(_ completion: @escaping (Result<Message, Error>) -> Void) {
        receiveExactly(Self.headerSize) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let header):
                guard header.readBigEndian(UInt16.self, at: 0) == Self.magic else {
                    completion(.failure(StreamError.badMessage))
                    return
                }
                let type = header[2]
                let flags = header[3]
                let length = Int(header.readBigEndian(UInt32.self, at: 4))
                let timestamp = header.readBigEndian(UInt64.self, at: 8)
                guard length <= 1_000_000 else {
                    completion(.failure(StreamError.badMessage))
                    return
                }
                self.receiveExactly(length) { result in
                    completion(result.map { Message(type: type, flags: flags, timestampUs: timestamp, payload: $0) })
                }
            }
        }
    }

    private func receiveExactly(_ count: Int, _ completion: @escaping (Result<Data, Error>) -> Void) {
        guard count > 0 else {
            completion(.success(Data()))
            return
        }
        connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
            if let error {
                completion(.failure(error))
            } else if let data, data.count == count {
                completion(.success(Data(data))) // re-base indices at 0
            } else {
                completion(.failure(StreamError.closed("The TV closed the connection.")))
            }
        }
    }

    private static func nowUs() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds / 1000
    }
}

// MARK: - Big-endian helpers

private extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    func readBigEndian<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
        var value: T = 0
        for byte in self[offset..<(offset + MemoryLayout<T>.size)] {
            value = (value << 8) | T(byte)
        }
        return value
    }
}
