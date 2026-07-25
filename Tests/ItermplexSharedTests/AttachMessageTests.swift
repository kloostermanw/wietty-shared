import Testing
import Foundation
@testable import ItermplexShared

@Suite struct AttachMessageTests {
    @Test func parsesResize() {
        #expect(AttachMessage.parse("{\"type\":\"resize\",\"cols\":120,\"rows\":40}")
                == .resize(cols: 120, rows: 40))
    }

    @Test func parsesData() {
        #expect(AttachMessage.parse("{\"type\":\"data\",\"vt\":\"hi\"}")
                == .data(Array("hi".utf8)))
    }

    @Test func parsesEnded() {
        #expect(AttachMessage.parse("{\"type\":\"ended\"}") == .ended)
    }

    @Test func anUnknownTypeIsNil() {
        #expect(AttachMessage.parse("{\"type\":\"something-new\"}") == nil)
    }

    @Test func malformedJSONIsNil() {
        #expect(AttachMessage.parse("not json") == nil)
        #expect(AttachMessage.parse("") == nil)
        #expect(AttachMessage.parse("[1,2,3]") == nil)
    }

    @Test func aResizeMissingItsDimensionsIsNil() {
        #expect(AttachMessage.parse("{\"type\":\"resize\",\"cols\":120}") == nil)
    }

    @Test func aDataMessageMissingItsPayloadIsNil() {
        #expect(AttachMessage.parse("{\"type\":\"data\"}") == nil)
    }

    @Test func multibyteDataSurvivesAsUTF8Bytes() {
        #expect(AttachMessage.parse("{\"type\":\"data\",\"vt\":\"é\"}")
                == .data(Array("é".utf8)))
    }

    @Test func encodesInputAsADataObject() throws {
        let json = try #require(AttachMessage.encodeInput(Array("ls\r".utf8)[...]))
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        #expect(object["data"] as? String == "ls\r")
    }

    @Test func encodingEscapesQuotesAndControlBytes() throws {
        let json = try #require(AttachMessage.encodeInput(Array("say \"hi\"\n".utf8)[...]))
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        #expect(object["data"] as? String == "say \"hi\"\n")
    }
}
