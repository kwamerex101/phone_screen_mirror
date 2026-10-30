import XCTest
@testable import iMirror

final class MJPEGStreamParserTests: XCTestCase {
    private let response = Data("HTTP/1.0 200 OK\r\nContent-Type: multipart/x-mixed-replace\r\n\r\n".utf8)
    private func part(_ payload: String) -> Data {
        Data("--BoundaryString\r\nContent-type: image/jpeg\r\nContent-Length: \(payload.utf8.count)\r\n\r\n\(payload)\r\n".utf8)
    }

    func testEverySplitPreservesFramesIncludingSplitHeadersAndPayload() throws {
        let stream = response + part("first") + part("second")
        for split in 0...stream.count {
            var parser = MJPEGStreamParser()
            let early = try parser.append(Data(stream.prefix(split)))
            let late = try parser.append(Data(stream.dropFirst(split)))
            XCTAssertEqual(late ?? early, Data("second".utf8), "split at \(split)")
        }
    }

    func testCoalescedFramesReturnOnlyNewestCompletePayload() throws {
        var parser = MJPEGStreamParser()
        let batch = response + part("old") + part("new") + Data(part("partial").dropLast(5))
        XCTAssertEqual(try parser.append(batch), Data("new".utf8))
    }

    func testSingleByteChunks() throws {
        var parser = MJPEGStreamParser()
        var frames: [Data] = []
        for byte in response + part("first") + part("second") {
            if let frame = try parser.append(Data([byte])) { frames.append(frame) }
        }
        XCTAssertEqual(frames, [Data("first".utf8), Data("second".utf8)])
    }

    func testRejectsInvalidLengthsBeforeWaitingForPayload() {
        for length in ["-1", "0", "999999999999999999999999", "8388609", "+1", "1x", ""] {
            var parser = MJPEGStreamParser()
            let stream = response + Data("--BoundaryString\r\nContent-Length: \(length)\r\n\r\n".utf8)
            XCTAssertThrowsError(try parser.append(stream), length)
        }
    }

    func testRejectsMissingAndDuplicateLengths() {
        for headers in ["Content-Type: image/jpeg", "Content-Length: 1\r\nContent-Length: 2"] {
            var parser = MJPEGStreamParser()
            XCTAssertThrowsError(try parser.append(response + Data("--BoundaryString\r\n\(headers)\r\n\r\n".utf8)))
        }
    }

    func testBoundsIncompleteResponsePartHeadersAndBoundarySearch() throws {
        let junk = Data(repeating: 65, count: MJPEGStreamParser.maximumHeaderBytes + 1)
        for prefix in [Data(), response, response + Data("--BoundaryString\r\n".utf8)] {
            var parser = MJPEGStreamParser()
            XCTAssertThrowsError(try parser.append(prefix + junk))
        }
        var parser = MJPEGStreamParser()
        XCTAssertThrowsError(try parser.append(junk + Data("\r\n\r\n".utf8)))
    }
}
