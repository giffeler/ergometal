import Testing
@testable import MetalErgoCore

struct DonationTests {
    @Test func testRejectsInvalidConfiguration() {
        #expect(throws: (any Error).self) { try DonationSchedule(percent: -1) }
        #expect(throws: (any Error).self) { try DonationSchedule(percent: 101) }
        #expect(throws: (any Error).self) { try DonationSchedule(percent: 1, cycleSeconds: 0) }
    }

    @Test func testDisabledScheduleAlwaysSelectsUser() throws {
        let schedule = try DonationSchedule(percent: 0)

        #expect(!schedule.isEnabled)
        #expect(schedule.recipient(at: 0) == .user)
        #expect(schedule.recipient(at: 60_000) == .user)
        #expect(schedule.nextBoundary(after: 0) == nil)
    }

    @Test func testOnePercentUsesLastMinuteOfHundredMinuteCycle() throws {
        let schedule = try DonationSchedule(percent: 1)

        #expect(schedule.recipient(at: 0) == .user)
        #expect(schedule.recipient(at: 5_939.999) == .user)
        #expect(schedule.recipient(at: 5_940) == .donation)
        #expect(schedule.recipient(at: 5_999.999) == .donation)
        #expect(schedule.recipient(at: 6_000) == .user)
        #expect(schedule.nextBoundary(after: 0) == 5_940)
        #expect(schedule.nextBoundary(after: 5_940) == 6_000)
        #expect(schedule.nextBoundary(after: 6_000) == 11_940)
    }

    @Test func testRepresentativePercentagesAndCycleRollover() throws {
        let half = try DonationSchedule(percent: 50, cycleSeconds: 100)
        #expect(half.recipient(at: 49.999) == .user)
        #expect(half.recipient(at: 50) == .donation)
        #expect(half.recipient(at: 100) == .user)

        let ninetyNine = try DonationSchedule(percent: 99, cycleSeconds: 100)
        #expect(ninetyNine.recipient(at: 0.999) == .user)
        #expect(ninetyNine.recipient(at: 1) == .donation)
        #expect(ninetyNine.cycleIndex(at: 200) == 2)
    }

    @Test func testHundredPercentRetriesAtEachCycleBoundary() throws {
        let schedule = try DonationSchedule(percent: 100, cycleSeconds: 100)

        #expect(schedule.recipient(at: 0) == .donation)
        #expect(schedule.recipient(at: 99.999) == .donation)
        #expect(schedule.recipient(at: 100) == .donation)
        #expect(schedule.nextBoundary(after: 0) == 100)
        #expect(schedule.nextBoundary(after: 100) == 200)
    }
}
