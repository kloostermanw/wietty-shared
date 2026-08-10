import Foundation

/// One message on a `/attach` socket, in either direction.
///
/// Extracted from the socket handling so the protocol's framing is testable without a
/// live server: the parser is where a server side format change would first show up.
public enum AttachMessage: Equatable, Sendable {
    /// The remote session's grid size. The client has no say in this: the protocol has
    /// no upstream resize, so the Mac's session size wins.
    case resize(cols: Int, rows: Int)
    /// VT bytes to feed the terminal.
    case data([UInt8])
    /// The session is gone. No further messages will arrive.
    case ended

    /// `nil` for an unknown message type, a message missing the fields its type needs,
    /// or anything that is not a JSON object. An unknown type is not an error: it is a
    /// newer server saying something this client does not need to understand.
    public static func parse(_ text: String) -> AttachMessage? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        switch object["type"] as? String {
        case "resize":
            guard let cols = object["cols"] as? Int, let rows = object["rows"] as? Int else { return nil }
            return .resize(cols: cols, rows: rows)
        case "data":
            guard let vt = object["vt"] as? String else { return nil }
            return .data(Array(vt.utf8))
        case "ended":
            return .ended
        default:
            return nil
        }
    }

    /// Encodes keystroke bytes as the `{"data":"..."}` frame the server expects.
    public static func encodeInput(_ bytes: ArraySlice<UInt8>) -> String? {
        let text = String(decoding: bytes, as: UTF8.self)
        guard let data = try? JSONSerialization.data(withJSONObject: ["data": text]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
