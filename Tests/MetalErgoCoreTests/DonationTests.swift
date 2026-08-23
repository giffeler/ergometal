import XCTest
@testable import MetalErgoCore

final class DonationTests: XCTestCase {
    func testRejectsInvalidConfiguration() {
        XCTAssertThrowsError(try DonationSchedule(percent: -1))
        XCTAssertThrowsError(try DonationSchedule(percent: 101))
        XCTAssertThrowsError(try DonationSchedule(percent: 1, cycleSeconds: 0))
    }

    func testDisabledScheduleAlwaysSelectsUser() throws {
        let schedule = try DonationSchedule(percent: 0)

        XCTAssertFalse(schedule.isEnabled)
        XCTAssertEqual(schedule.recipient(at: 0), .user)
        XCTAssertEqual(schedule.recipient(at: 60_000), .user)
        XCTAssertNil(schedule.nextBoundary(after: 0))
    }

    func testOnePercentUsesLastMinuteOfHundredMinuteCycle() throws {
        let schedule = try DonationSchedule(percent: 1)

        XCTAssertEqual(schedule.recipient(at: 0), .user)
        XCTAssertEqual(schedule.recipient(at: 5_939.999), .user)
        XCTAssertEqual(schedule.recipient(at: 5_940), .donation)
        XCTAssertEqual(schedule.recipient(at: 5_999.999), .donation)
        XCTAssertEqual(schedule.recipient(at: 6_000), .user)
        XCTAssertEqual(schedule.nextBoundary(after: 0), 5_940)
        XCTAssertEqual(schedule.nextBoundary(after: 5_940), 6_000)
        XCTAssertEqual(schedule.nextBoundary(after: 6_000), 11_940)
    }

    func testRepresentativePercentagesAndCycleRollover() throws {
        let half = try DonationSchedule(percent: 50, cycleSeconds: 100)
        XCTAssertEqual(half.recipient(at: 49.999), .user)
        XCTAssertEqual(half.recipient(at: 50), .donation)
        XCTAssertEqual(half.recipient(at: 100), .user)

        let ninetyNine = try DonationSchedule(percent: 99, cycleSeconds: 100)
        XCTAssertEqual(ninetyNine.recipient(at: 0.999), .user)
        XCTAssertEqual(ninetyNine.recipient(at: 1), .donation)
        XCTAssertEqual(ninetyNine.cycleIndex(at: 200), 2)
    }

    func testHundredPercentRetriesAtEachCycleBoundary() throws {
        let schedule = try DonationSchedule(percent: 100, cycleSeconds: 100)

        XCTAssertEqual(schedule.recipient(at: 0), .donation)
        XCTAssertEqual(schedule.recipient(at: 99.999), .donation)
        XCTAssertEqual(schedule.recipient(at: 100), .donation)
        XCTAssertEqual(schedule.nextBoundary(after: 0), 100)
        XCTAssertEqual(schedule.nextBoundary(after: 100), 200)
    }
}
