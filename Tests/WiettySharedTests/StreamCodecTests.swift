import Foundation
import Testing
@testable import WiettyShared

struct StreamCodecTests {
    static let all: [StreamMessage] = [
        .hello(protocolVersion: 2, session: "gt:abc", resize: .reflow),
        .hello(protocolVersion: 2, session: nil, resize: nil),
        .error(code: "protocol", message: "Update Wietty."),
        .resize(cols: 120, rows: 40, own: true),
        .resize(cols: 80, rows: 24, own: false),
        .snapshot([0x1B, 0x63, 0xFF, 0x00]),
        .repaint([0x1B, 0x5B, 0x48]),
        .data([0xC3, 0x28, 0x00, 0xFF]),          // not valid UTF-8, on purpose
        .data([]),
        .ended,
    ]

    @Test func everyMessageSurvivesTheWebSocketFraming() {
        for message in Self.all {
            #expect(StreamCodec.message(from: StreamCodec.webSocketFrame(for: message)) == message)
        }
    }

    @Test func terminalBytesTravelAsBinaryAndControlAsText() {
        guard case .binary(let bytes) = StreamCodec.webSocketFrame(for: .data([0x41])) else {
            Issue.record("data must be a binary frame"); return
        }
        #expect(bytes == [0x02, 0x41])
        guard case .text = StreamCodec.webSocketFrame(for: .ended) else {
            Issue.record("ended must be a text frame"); return
        }
    }

    @Test func everyMessageSurvivesTheSocketFramingInOneBuffer() throws {
        var reader = StreamFrameReader()
        let wire = Self.all.flatMap(StreamCodec.socketFrame(for:))
        #expect(try reader.append(wire) == Self.all)
    }

    @Test func aFrameSplitAtEveryByteStillDecodes() throws {
        let wire = Self.all.flatMap(StreamCodec.socketFrame(for:))
        var reader = StreamFrameReader()
        var decoded: [StreamMessage] = []
        for byte in wire { decoded += try reader.append([byte]) }
        #expect(decoded == Self.all)
    }

    @Test func aSocketFrameIsLengthThenTypeThenPayload() {
        #expect(StreamCodec.socketFrame(for: .data([0x41, 0x42])) == [0, 0, 0, 3, 0x02, 0x41, 0x42])
    }

    @Test func anOversizedFrameIsAnErrorAndNotAnAllocation() {
        var reader = StreamFrameReader(maxPayload: 16)
        #expect(throws: StreamFrameError.frameTooLarge) {
            _ = try reader.append([0, 0, 1, 0, 0x02])
        }
    }

    @Test func anUnknownTypeByteIsSkippedAndTheNextFrameStillDecodes() throws {
        var reader = StreamFrameReader()
        let wire: [UInt8] = [0, 0, 0, 2, 0x7F, 0x00] + StreamCodec.socketFrame(for: .ended)
        #expect(try reader.append(wire) == [.ended])
    }

    @Test func unknownOrBrokenJSONIsNoMessage() {
        #expect(StreamCodec.message(from: .text(#"{"type":"later"}"#)) == nil)
        #expect(StreamCodec.message(from: .text("not json")) == nil)
        #expect(StreamCodec.message(from: .text(#"{"type":"resize","cols":80}"#)) == nil)
        #expect(StreamCodec.message(from: .binary([])) == nil)
        #expect(StreamCodec.message(from: .binary([0x7F, 1])) == nil)
    }

    @Test func aResizeWithoutOwnReadsAsNotOwn() {
        #expect(StreamCodec.message(from: .text(#"{"type":"resize","cols":80,"rows":24}"#))
                == .resize(cols: 80, rows: 24, own: false))
    }

    // MARK: Fix round 1

    static func paddedHello(totalBytes: Int) -> [UInt8] {
        let base = Array(#"{"type":"hello","protocol":2,"session":""}"#.utf8)
        return Array(#"{"type":"hello","protocol":2,"session":""#.utf8)
            + [UInt8](repeating: 0x61, count: totalBytes - base.count) + Array(#""}"#.utf8)
    }

    @Test func literalJSONDecodes() {
        #expect(StreamCodec.message(from: .text(#"{"type":"hello","protocol":2,"session":"gt:abc","resize":"reflow"}"#))
                == .hello(protocolVersion: 2, session: "gt:abc", resize: .reflow))
        #expect(StreamCodec.message(from: .text(#"{"type":"error","code":"protocol","message":"x"}"#))
                == .error(code: "protocol", message: "x"))
    }

    @Test func literalJSONEncodes() throws {
        func object(_ message: StreamMessage) throws -> [String: Any] {
            guard case .text(let text) = StreamCodec.webSocketFrame(for: message) else {
                Issue.record("expected text"); return [:]
            }
            return try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        }
        let hello = try object(.hello(protocolVersion: 2, session: "gt:abc", resize: .reflow))
        #expect(hello.count == 4)
        #expect(hello["type"] as? String == "hello")
        #expect(hello["protocol"] as? Int == 2)
        #expect(hello["session"] as? String == "gt:abc")
        #expect(hello["resize"] as? String == "reflow")
        let error = try object(.error(code: "protocol", message: "x"))
        #expect(error.count == 3)
        #expect(error["type"] as? String == "error")
        #expect(error["code"] as? String == "protocol")
        #expect(error["message"] as? String == "x")
    }

    @Test func aJSONSocketFrameHasExactBytes() {
        let payload = Array(#"{"type":"ended"}"#.utf8)
        #expect(StreamCodec.socketFrame(for: .ended) == [0, 0, 0, UInt8(payload.count + 1), 0x01] + payload)
    }

    /// The reader's default is the protocol's largest message, the same limit the
    /// WebSocket transport is given. Only the length fields are fed, so nothing of that
    /// size is allocated: a frame of exactly the limit is merely incomplete, one byte more
    /// is refused.
    @Test func theReadersDefaultIsTheProtocolsLargestMessage() throws {
        #expect(StreamProtocol.maxMessageSize == 64 << 20)
        func header(payload: Int) -> [UInt8] {
            let length = UInt32(payload + 1)
            return [UInt8(length >> 24), UInt8((length >> 16) & 0xFF),
                    UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF), 0x03]
        }
        var atLimit = StreamFrameReader()
        #expect(try atLimit.append(header(payload: StreamProtocol.maxMessageSize)) == [])
        var overLimit = StreamFrameReader()
        #expect(throws: StreamFrameError.frameTooLarge) {
            _ = try overLimit.append(header(payload: StreamProtocol.maxMessageSize + 1))
        }
    }

    @Test func readerBoundaries() throws {
        var zero = StreamFrameReader()
        #expect(throws: StreamFrameError.malformedFrame) { _ = try zero.append([0, 0, 0, 0]) }
        var huge = StreamFrameReader()
        #expect(throws: StreamFrameError.frameTooLarge) { _ = try huge.append([0xFF, 0xFF, 0xFF, 0xFF]) }

        var exact = StreamFrameReader(maxPayload: 16)
        let body = [UInt8](repeating: 7, count: 16)
        #expect(try exact.append(StreamCodec.socketFrame(for: .data(body))) == [.data(body)])
        var over = StreamFrameReader(maxPayload: 16)
        #expect(throws: StreamFrameError.frameTooLarge) {
            _ = try over.append(StreamCodec.socketFrame(for: .data(body + [7])))
        }

        var empty = StreamFrameReader()
        #expect(try empty.append([0, 0, 0, 1, 0x01]) == [])
        #expect(StreamCodec.message(from: .text("[]")) == nil)
        #expect(StreamCodec.message(from: .text("5")) == nil)
        #expect(StreamCodec.message(from: .text(#"{"type":5}"#)) == nil)
    }

    @Test func aBadFrameDoesNotSwallowTheGoodOnesBeforeItAndLatches() throws {
        var reader = StreamFrameReader()
        let good = StreamCodec.socketFrame(for: .data([1, 2]))
        #expect(try reader.append(good + [0, 0, 0, 0]) == [.data([1, 2])])
        #expect(throws: StreamFrameError.malformedFrame) { _ = try reader.append([]) }
        #expect(throws: StreamFrameError.malformedFrame) { _ = try reader.append(good) }
    }

    @Test func aJSONPayloadIsCappedAt64KiB() throws {
        let max = StreamCodec.maxJSONPayload
        #expect(max == 65_536)
        let big = Self.paddedHello(totalBytes: max + 1)
        let ok = Self.paddedHello(totalBytes: max)
        #expect(StreamCodec.message(from: .text(String(decoding: big, as: UTF8.self))) == nil)
        #expect(StreamCodec.message(from: .text(String(decoding: ok, as: UTF8.self))) != nil)
        func frame(_ payload: [UInt8]) -> [UInt8] {
            let n = UInt32(payload.count + 1)
            return [UInt8(n >> 24), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF), 0x01] + payload
        }
        var r1 = StreamFrameReader()
        #expect(try r1.append(frame(big)) == [])
        var r2 = StreamFrameReader()
        #expect(try r2.append(frame(ok)).count == 1)
    }

    @Test func resizeIsRangeChecked() {
        func decode(_ c: Int, _ r: Int) -> StreamMessage? {
            StreamCodec.message(from: .text(#"{"type":"resize","cols":\#(c),"rows":\#(r)}"#))
        }
        #expect(decode(0, 10) == nil)
        #expect(decode(-5, 10) == nil)
        #expect(decode(10, 10_001) == nil)
        #expect(decode(1, 1) == .resize(cols: 1, rows: 1, own: false))
        #expect(decode(10_000, 10_000) == .resize(cols: 10_000, rows: 10_000, own: false))
    }

    @Test func failureIsSetAtOnceByTheAppendThatMetTheBadFrame() throws {
        var reader = StreamFrameReader()
        let good = StreamCodec.socketFrame(for: .data([1, 2]))
        #expect(reader.failure == nil)
        #expect(try reader.append(good + [0, 0, 0, 0]) == [.data([1, 2])])
        #expect(reader.failure == .malformedFrame)
        var big = StreamFrameReader(maxPayload: 16)
        #expect(throws: StreamFrameError.frameTooLarge) { _ = try big.append([0, 0, 1, 0, 0x02]) }
        #expect(big.failure == .frameTooLarge)
    }

    @Test func failureIsNilOnASoundStreamAndAfterASkippedUnknownType() throws {
        var reader = StreamFrameReader()
        let wire = Self.all.flatMap(StreamCodec.socketFrame(for:))
        _ = try reader.append(wire)
        #expect(reader.failure == nil)
        #expect(try reader.append([0, 0, 0, 2, 0x7F, 0x00]) == [])
        #expect(reader.failure == nil)
    }

    @Test func aCheckedSocketFrameRefusesOnePayloadByteOverTheLimit() throws {
        let limit = 16
        let atLimit = StreamMessage.data([UInt8](repeating: 7, count: limit))
        #expect(try StreamCodec.checkedSocketFrame(for: atLimit, maxPayload: limit)
                == StreamCodec.socketFrame(for: atLimit))
        let over = StreamMessage.data([UInt8](repeating: 7, count: limit + 1))
        #expect(throws: StreamFrameError.frameTooLarge) {
            _ = try StreamCodec.checkedSocketFrame(for: over, maxPayload: limit)
        }
        #expect(try StreamCodec.checkedSocketFrame(for: .ended) == StreamCodec.socketFrame(for: .ended))
    }

    @Test func resizeWithZeroRowsOrTooManyColsIsNoMessage() {
        #expect(StreamCodec.message(from: .text(#"{"type":"resize","cols":10,"rows":0}"#)) == nil)
        #expect(StreamCodec.message(from: .text(#"{"type":"resize","cols":10001,"rows":10}"#)) == nil)
    }
}
