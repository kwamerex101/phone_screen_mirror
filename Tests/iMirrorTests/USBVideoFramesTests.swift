import XCTest
import CoreVideo
@testable import iMirror

final class USBVideoFramesTests: XCTestCase {
    func testScreenshotUsesNewestSurfaceAfterDisplayChanges() throws {
        let frames = USBVideoFrames()
        XCTAssertNil(frames.screenshot())
        XCTAssertFalse(frames.hasFrame)
        let portrait = try buffer(width: 40, height: 80)
        frames.receive(portrait, at: 1)
        let first = try XCTUnwrap(frames.screenshot())
        XCTAssertEqual(first.width, 40)
        XCTAssertEqual(first.height, 80)

        let opened = try buffer(width: 120, height: 80)
        frames.receive(opened, at: 2)
        let second = try XCTUnwrap(frames.screenshot())
        XCTAssertEqual(second.width, 120)
        XCTAssertEqual(second.height, 80)
        frames.clearImage()
        XCTAssertFalse(frames.hasFrame)
        XCTAssertNil(frames.screenshot(), "Disconnect must revoke the previous phone image")
    }

    func testCaptureCadenceIsMeasuredFromDeliveredFrames() throws {
        let frames = USBVideoFrames()
        let image = try buffer(width: 8, height: 8)
        for index in 0...60 { frames.receive(image, at: 10 + Double(index) / 60) }
        XCTAssertEqual(frames.statistics, "60.0 FPS (61 frames)")
        frames.reset()
        XCTAssertFalse(frames.hasFrame)
        XCTAssertEqual(frames.statistics, "0.0 FPS (0 frames)")
    }

    private func buffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let result = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        XCTAssertEqual(result, kCVReturnSuccess)
        return try XCTUnwrap(buffer)
    }
}
