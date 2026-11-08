import XCTest
@testable import iMirror

final class CoreDeviceDisplayTests: XCTestCase {
    func testUnfoldedDisplayUsesItsOwnTouchscreenAndNativeAxes() {
        let displays = """
        {"result":{"displays":[
          {"active":false,"primary":true,"uniqueId":"outer","nativeSize":[1398,2034],
           "nativeOrientation":"rot0","currentOrientation":"rot0","type":{"integrated":{}}},
          {"active":true,"primary":false,"uniqueId":"inner","nativeSize":[1878,2670],
           "nativeOrientation":"rot0","currentOrientation":"rot90","type":{"integrated":{}}},
          {"active":true,"uniqueId":"mirror","type":{"wireless":{}}}
        ]}}
        """
        let descriptors = """
        connectedDescriptor[0] serviceID:0x101 string:"CoreDevice touchscreen(outer)"
        connectedDescriptor[1] serviceID:0x102 string:"CoreDevice touchscreen(inner)"
        connectedDescriptor[2] serviceID:0x200 string:"CoreDevice keyboard"
        """
        let frameSize = CGSize(width: 2034, height: 1432)
        let target = CoreDeviceControl.activeTouchDisplay(displays, frameSize: frameSize)
        XCTAssertEqual(target?.uniqueID, "inner")
        XCTAssertEqual(target?.quarter, 1)
        XCTAssertEqual(CoreDeviceControl.touchscreenDescriptors(descriptors)["inner"], "0x102")
        XCTAssertNil(CoreDeviceControl.activeTouchDisplay(displays, frameSize: CGSize(width: 1398, height: 2034)))
        XCTAssertEqual(CoreDeviceControl.rotateTouch(["swipe", "0.25", "0.75", "0.5", "0.125", "0.3"], quarter: 1),
                       ["swipe", "0.75", "0.75", "0.125", "0.5", "0.3"])
    }
}
