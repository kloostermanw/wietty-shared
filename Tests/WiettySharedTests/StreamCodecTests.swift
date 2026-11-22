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
}
