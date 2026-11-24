import Foundation

public enum StreamFrameError: Error, Equatable {
    /// The length field is above the reader's maximum.
    case frameTooLarge
    /// The length field is zero, so there is not even a type byte.
    case malformedFrame
}

public enum StreamCodec {
    public enum WebSocketFrame: Equatable, Sendable {
        case text(String)
        case binary([UInt8])
    }

    /// The most bytes a JSON payload may have. A longer one is no message.
    static let maxJSONPayload = 65_536
    static let resizeRange = 1...10_000

    static let jsonType: UInt8 = 0x01
    static let dataType: UInt8 = 0x02
    static let snapshotType: UInt8 = 0x03
    static let repaintType: UInt8 = 0x04

    // MARK: WebSocket

    public static func webSocketFrame(for message: StreamMessage) -> WebSocketFrame {
        switch message {
        case .data(let bytes): return .binary([dataType] + bytes)
        case .snapshot(let bytes): return .binary([snapshotType] + bytes)
        case .repaint(let bytes): return .binary([repaintType] + bytes)
        case .hello, .error, .resize, .ended:
            return .text(String(decoding: json(for: message) ?? [], as: UTF8.self))
        }
    }

    public static func message(from frame: WebSocketFrame) -> StreamMessage? {
        switch frame {
        case .text(let text): return message(json: Array(text.utf8))
        case .binary(let bytes):
            guard let type = bytes.first else { return nil }
            return message(type: type, payload: Array(bytes.dropFirst()))
        }
    }

    // MARK: Unix socket

    /// Four bytes of big endian length (type byte plus payload), the type byte, the payload.
    public static func socketFrame(for message: StreamMessage) -> [UInt8] {
        let type: UInt8
        let payload: [UInt8]
        switch message {
        case .data(let bytes): (type, payload) = (dataType, bytes)
        case .snapshot(let bytes): (type, payload) = (snapshotType, bytes)
        case .repaint(let bytes): (type, payload) = (repaintType, bytes)
        case .hello, .error, .resize, .ended: (type, payload) = (jsonType, json(for: message) ?? [])
        }
        let length = UInt32(payload.count + 1)
        return [UInt8(length >> 24), UInt8((length >> 16) & 0xFF),
                UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF), type] + payload
    }

    /// As `socketFrame(for:)`, and throws `.frameTooLarge` for a payload the reader
    /// on the other side would refuse.
    public static func checkedSocketFrame(for message: StreamMessage,
                                          maxPayload: Int = StreamProtocol.maxMessageSize) throws -> [UInt8] {
        let frame = socketFrame(for: message)
        // The frame is four length bytes and a type byte, then the payload.
        guard frame.count - 5 <= maxPayload else { throw StreamFrameError.frameTooLarge }
        return frame
    }

    // MARK: Shared

    static func message(type: UInt8, payload: [UInt8]) -> StreamMessage? {
        switch type {
        case jsonType: return message(json: payload)
        case dataType: return .data(payload)
        case snapshotType: return .snapshot(payload)
        case repaintType: return .repaint(payload)
        default: return nil
        }
    }

    static func json(for message: StreamMessage) -> [UInt8]? {
        var object: [String: Any]
        switch message {
        case let .hello(version, session, resize):
            object = ["type": "hello", "protocol": version]
            if let session { object["session"] = session }
            if let resize { object["resize"] = resize.rawValue }
        case let .error(code, text):
            object = ["type": "error", "code": code, "message": text]
        case let .resize(cols, rows, own):
            object = ["type": "resize", "cols": cols, "rows": rows, "own": own]
        case .ended:
            object = ["type": "ended"]
        case .data, .snapshot, .repaint:
            return nil
        }
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return Array(data ?? Data())
    }

    static func message(json bytes: [UInt8]) -> StreamMessage? {
        guard bytes.count <= maxJSONPayload,
              let object = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any]
        else { return nil }
        switch object["type"] as? String {
        case "hello":
            guard let version = object["protocol"] as? Int else { return nil }
            return .hello(protocolVersion: version,
                          session: object["session"] as? String,
                          resize: (object["resize"] as? String).flatMap(ResizeMode.init(rawValue:)))
        case "error":
            guard let code = object["code"] as? String else { return nil }
            return .error(code: code, message: object["message"] as? String ?? "")
        case "resize":
            guard let cols = object["cols"] as? Int, let rows = object["rows"] as? Int,
                  resizeRange.contains(cols), resizeRange.contains(rows) else { return nil }
            return .resize(cols: cols, rows: rows, own: object["own"] as? Bool ?? false)
        case "ended":
            return .ended
        default:
            return nil
        }
    }
}

/// Turns the bytes read from a Unix socket back into messages.
///
/// A frame of an unknown type is skipped, which is how a newer peer can say something
/// this one does not need. A frame longer than `maxPayload` is an error, raised before
/// anything is allocated for it: the length is the peer's claim, not a fact.
///
/// An error is final. The call that meets a bad frame returns the messages decoded before
/// it (or throws at once if there were none), and every later call throws the same error.
/// The caller must close the connection when `append` throws. `failure` reports the error
/// as soon as the append that met it has returned, so a peer that then goes quiet is still seen.
public struct StreamFrameReader: Sendable {
    private var buffer: [UInt8] = []
    private let maxPayload: Int
    private var latched: StreamFrameError?

    /// The error that ended this reader, as soon as the append that met it has
    /// returned. Nil while the stream is sound.
    public var failure: StreamFrameError? { latched }

    public init(maxPayload: Int = StreamProtocol.maxMessageSize) {
        self.maxPayload = maxPayload
    }

    public mutating func append(_ bytes: [UInt8]) throws -> [StreamMessage] {
        if let latched { throw latched }
        buffer += bytes
        var messages: [StreamMessage] = []
        var offset = 0
        while buffer.count - offset >= 4 {
            let raw = UInt32(buffer[offset]) << 24 | UInt32(buffer[offset + 1]) << 16
                | UInt32(buffer[offset + 2]) << 8 | UInt32(buffer[offset + 3])
            var error: StreamFrameError?
            if raw == 0 {
                error = .malformedFrame
            } else if raw - 1 > UInt32(clamping: maxPayload) {
                error = .frameTooLarge
            }
            if let error {
                latched = error
                buffer = []
                if messages.isEmpty { throw error }
                return messages
            }
            let length = Int(raw)
            guard buffer.count - offset >= 4 + length else { break }
            let type = buffer[offset + 4]
            let payload = Array(buffer[(offset + 5)..<(offset + 4 + length)])
            if let message = StreamCodec.message(type: type, payload: payload) { messages.append(message) }
            offset += 4 + length
        }
        buffer.removeFirst(offset)
        return messages
    }
}
