import XCTest
@testable import iMirrorCore

final class ChainRecoveryClockTests: XCTestCase {
    func testInitialBootRestartSurvivesTheNextProbeTick() {
        var clock = ChainRecoveryClock()
        clock.runwdaStarted(at: 0)
        XCTAssertEqual(clock.action(at: 90, postConnectionOutage: false), .restartChain)
        clock.beginRestart(at: 90)
        XCTAssertEqual(clock.action(at: 93, postConnectionOutage: false), .wait)
        XCTAssertEqual(clock.action(at: 94, postConnectionOutage: false), .wait)
    }

    func testPreparationAndRunwdaEachReceiveFullGraceWithoutAnotherRestart() {
        var clock = ChainRecoveryClock()
        clock.connectionLost(at: 0)
        XCTAssertEqual(clock.action(at: 30, postConnectionOutage: true), .restartChain)
        clock.beginRestart(at: 30)
        XCTAssertEqual(clock.action(at: 100, postConnectionOutage: true), .wait)
        clock.runwdaStarted(at: 110)
        XCTAssertEqual(clock.action(at: 199, postConnectionOutage: true), .wait)
        XCTAssertEqual(clock.action(at: 200, postConnectionOutage: true), .giveUp)
    }

    func testRestartThatNeverLaunchesRunwdaStillExpires() {
        var clock = ChainRecoveryClock()
        clock.beginRestart(at: 90)
        XCTAssertEqual(clock.action(at: 179, postConnectionOutage: false), .wait)
        XCTAssertEqual(clock.action(at: 180, postConnectionOutage: false), .giveUp)
    }

    func testRepeatedDownProbesCannotPostponeRecovery() {
        var clock = ChainRecoveryClock()
        clock.connectionLost(at: 10)
        clock.connectionLost(at: 39)
        XCTAssertEqual(clock.action(at: 40, postConnectionOutage: true), .restartChain)
        clock.reset()
        XCTAssertEqual(clock.stage, 0)
        XCTAssertEqual(clock.action(at: 200, postConnectionOutage: true), .wait)
    }
}
