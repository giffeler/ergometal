import Foundation
import MetalErgoCore

protocol MiningStratumClient: AnyObject, Sendable {
    func connect()
    func disconnect()
    @discardableResult
    func submit(job: ErgoStratumJob, nonce: UInt64) throws -> Int
}

extension ErgoStratumClient: MiningStratumClient {}

struct MiningWork: Sendable {
    fileprivate let job: ErgoStratumJob
    let recipient: MiningRecipient

    var id: String { job.id }
    var height: Int { job.height }
    var message: [UInt8] { job.message }
    var target: UInt256 { job.target }
    var extraNoncePrefix: [UInt8] { job.extraNoncePrefix }
    var extraNonce2Size: Int { job.extraNonce2Size }
}

final class MiningCoordinator: @unchecked Sendable {
    let stats: StatisticsStore
    let writer: JSONLEventWriter

    private let condition = NSCondition()
    private let scheduleQueue = DispatchQueue(label: "dev.ergometal.donation-schedule")
    private let donationSchedule: DonationSchedule
    private let donationTimeoutSeconds: TimeInterval
    private let uptime: @Sendable () -> TimeInterval
    private let automaticallySchedules: Bool

    private var userClient: (any MiningStratumClient)?
    private var donationClient: (any MiningStratumClient)?
    private var activeClient: (any MiningStratumClient)?
    private var activeRecipient: MiningRecipient = .user
    private var scheduledRecipient: MiningRecipient = .user
    private var queuedJob: MiningWork?
    private var latestGeneration: UInt64 = 0
    private var latestHeight: Int?
    private var stopped = false
    private var stopFinalized = false
    private var reconnectAttempt = 0
    private var scheduleStartedAt: TimeInterval?
    private var boundaryWorkItem: DispatchWorkItem?
    private var donationTimeoutWorkItem: DispatchWorkItem?
    private var donationAuthorized = false
    private var donationJobReceived = false
    private var donationReady = false
    private var donationFailureInProgress = false
    private var currentCycleIndex = 0

    var beforeStop: (@Sendable () -> Void)?

    init(
        stats: StatisticsStore,
        writer: JSONLEventWriter,
        donationSchedule: DonationSchedule,
        donationTimeoutSeconds: TimeInterval = 15,
        uptime: @escaping @Sendable () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        },
        automaticallySchedules: Bool = true
    ) {
        self.stats = stats
        self.writer = writer
        self.donationSchedule = donationSchedule
        self.donationTimeoutSeconds = donationTimeoutSeconds
        self.uptime = uptime
        self.automaticallySchedules = automaticallySchedules
    }

    func configure(
        userClient: any MiningStratumClient,
        donationClient: (any MiningStratumClient)?
    ) {
        self.userClient = userClient
        self.donationClient = donationClient
    }

    func start() {
        let initialRecipient = donationSchedule.recipient(at: 0)
        condition.lock()
        guard !stopped, scheduleStartedAt == nil else {
            condition.unlock()
            return
        }
        scheduleStartedAt = uptime()
        scheduledRecipient = initialRecipient
        currentCycleIndex = 0
        condition.unlock()

        stats.configureDonation(
            percent: donationSchedule.percent,
            initialRecipient: initialRecipient)
        if initialRecipient == .donation {
            emitDonationWindow("donation_window_started", cycle: 0)
        }
        activate(initialRecipient, countSwitch: false)
        if automaticallySchedules { scheduleNextBoundary() }
    }

    func handle(_ event: StratumEvent) {
        condition.lock()
        let recipient = activeRecipient
        condition.unlock()
        handle(event, recipient: recipient)
    }

    func handle(_ event: StratumEvent, recipient: MiningRecipient) {
        if case .shareResult(_, let accepted, let message) = event {
            condition.lock()
            guard !stopped else {
                condition.unlock()
                return
            }
            stats.recordShareResult(recipient: recipient, accepted: accepted)
            emit(
                accepted ? "share_accepted" : "share_rejected",
                fieldsWithRecipient(
                    recipient,
                    recipient == .user
                        ? message.map { ["reason": $0] } ?? [:]
                        : [:]))
            condition.unlock()
            return
        }

        switch event {
        case .connected:
            condition.lock()
            guard !stopped, activeRecipient == recipient else {
                condition.unlock()
                return
            }
            stats.update {
                $0.poolConnected = true
                $0.state = .starting
                $0.lastError = nil
            }
            condition.unlock()
            emit("pool_connected", fieldsWithRecipient(recipient))
        case .authorized:
            condition.lock()
            guard !stopped, activeRecipient == recipient else {
                condition.unlock()
                return
            }
            reconnectAttempt = 0
            if recipient == .donation {
                donationAuthorized = true
                markDonationReadyIfPossible()
            }
            stats.update { $0.lastError = nil }
            condition.unlock()
            emit("pool_authorized", fieldsWithRecipient(recipient))
        case .difficulty(let value):
            condition.lock()
            guard !stopped, activeRecipient == recipient else {
                condition.unlock()
                return
            }
            stats.update { $0.job.difficulty = value }
            condition.unlock()
        case .job(let job):
            condition.lock()
            guard !stopped, activeRecipient == recipient else {
                condition.unlock()
                return
            }
            latestGeneration = job.generation
            latestHeight = job.height
            queuedJob = MiningWork(job: job, recipient: recipient)
            if recipient == .donation {
                donationJobReceived = true
                markDonationReadyIfPossible()
            }
            stats.update {
                $0.job = JobStatistics(
                    id: job.id,
                    height: job.height,
                    receivedAt: job.receivedAt,
                    difficulty: $0.job.difficulty,
                    targetHex: job.target.hex)
            }
            condition.broadcast()
            condition.unlock()
            emit("job_received", fieldsWithRecipient(recipient, [
                "id": job.id,
                "height": String(job.height),
                "job_target_hex": job.target.hex
            ]))
        case .protocolError(let message):
            condition.lock()
            guard !stopped, activeRecipient == recipient else {
                condition.unlock()
                return
            }
            stats.update {
                $0.protocolErrors += 1
                $0.lastError = recipient == .donation
                    ? "donation pool protocol error"
                    : message
            }
            condition.unlock()
            emit(
                "protocol_error",
                fieldsWithRecipient(
                    recipient,
                    recipient == .user ? ["message": message] : [:]))
            if recipient == .donation {
                failDonation(reason: "protocol_error")
            }
        case .disconnected(let message):
            if recipient == .donation {
                failDonation(reason: "disconnected")
            } else {
                reconnectUser(after: message)
            }
        case .shareResult:
            break
        }
    }

    func nextJob() -> MiningWork? {
        condition.lock()
        defer { condition.unlock() }
        while queuedJob == nil && !stopped {
            condition.wait(until: Date(timeIntervalSinceNow: 1))
        }
        let job = queuedJob
        queuedJob = nil
        return job
    }

    func isCurrent(_ work: MiningWork) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return !stopped
            && activeRecipient == work.recipient
            && latestGeneration == work.job.generation
    }

    func isRecipientCurrent(_ recipient: MiningRecipient) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return !stopped && activeRecipient == recipient
    }

    func isHeightCurrent(_ height: Int) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return !stopped && latestHeight == height
    }

    func isEitherHeightCurrent(_ first: Int, _ second: Int) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return !stopped && (latestHeight == first || latestHeight == second)
    }

    @discardableResult
    func submit(_ work: MiningWork, nonce: UInt64) throws -> Int {
        condition.lock()
        guard !stopped,
              activeRecipient == work.recipient,
              latestGeneration == work.job.generation,
              let client = activeClient
        else {
            condition.unlock()
            throw StratumError.notReady
        }
        condition.unlock()
        return try client.submit(job: work.job, nonce: nonce)
    }

    var isStopped: Bool {
        condition.lock()
        defer { condition.unlock() }
        return stopped
    }

    func recordStatisticsSample() {
        condition.lock()
        let shouldRecord = !stopped
        condition.unlock()
        guard shouldRecord else { return }
        let snapshot = stats.refresh()
        writer.write(MinerEvent(
            sessionID: snapshot.sessionID,
            type: "statistics_sample",
            fields: snapshot.eventFields))
    }

    /// Deterministic entry point used by the timer and by unit tests with a
    /// shortened cycle. The elapsed value is always relative to start().
    func advanceSchedule(to elapsedSeconds: TimeInterval) {
        guard donationSchedule.isEnabled else { return }
        let nextRecipient = donationSchedule.recipient(at: elapsedSeconds)
        let nextCycle = donationSchedule.cycleIndex(at: elapsedSeconds)

        condition.lock()
        guard !stopped else {
            condition.unlock()
            return
        }
        let previousScheduled = scheduledRecipient
        let previousCycle = currentCycleIndex
        let currentActive = activeRecipient
        scheduledRecipient = nextRecipient
        currentCycleIndex = nextCycle
        condition.unlock()

        if previousScheduled == .donation {
            emitDonationWindow("donation_window_ended", cycle: previousCycle)
        }
        stats.setDonationScheduledRecipient(nextRecipient)
        if nextRecipient == .donation {
            emitDonationWindow("donation_window_started", cycle: nextCycle)
        }
        if nextRecipient != currentActive {
            activate(
                nextRecipient,
                countSwitch: true,
                expectedCurrentRecipient: currentActive)
        }
    }

    func stop() {
        condition.lock()
        if stopped {
            while !stopFinalized { condition.wait() }
            condition.unlock()
            return
        }
        stopped = true
        boundaryWorkItem?.cancel()
        boundaryWorkItem = nil
        donationTimeoutWorkItem?.cancel()
        donationTimeoutWorkItem = nil
        queuedJob = nil
        latestHeight = nil
        condition.broadcast()
        condition.unlock()

        userClient?.disconnect()
        donationClient?.disconnect()
        beforeStop?()
        stats.finishDonationTiming()
        stats.update {
            $0.state = .stopped
            $0.poolConnected = false
        }
        let snapshot = stats.refresh()
        writer.write(MinerEvent(
            sessionID: snapshot.sessionID,
            type: "session_ended",
            fields: snapshot.eventFields))
        condition.lock()
        stopFinalized = true
        condition.broadcast()
        condition.unlock()
    }

    private func activate(
        _ recipient: MiningRecipient,
        countSwitch: Bool,
        expectedCurrentRecipient: MiningRecipient? = nil
    ) {
        condition.lock()
        guard !stopped else {
            condition.unlock()
            return
        }
        if let expectedCurrentRecipient,
           activeRecipient != expectedCurrentRecipient
        {
            condition.unlock()
            return
        }
        guard let nextClient = recipient == .user ? userClient : donationClient else {
            condition.unlock()
            if recipient == .donation { failDonation(reason: "configuration") }
            return
        }
        let previousClient = activeClient
        activeClient = nextClient
        activeRecipient = recipient
        latestGeneration &+= 1
        latestHeight = nil
        queuedJob = nil
        reconnectAttempt = 0
        donationAuthorized = false
        donationJobReceived = false
        donationReady = false
        donationFailureInProgress = false
        donationTimeoutWorkItem?.cancel()
        donationTimeoutWorkItem = nil
        condition.broadcast()
        condition.unlock()

        if let previousClient, previousClient !== nextClient {
            previousClient.disconnect()
        }
        stats.setActiveMiningRecipient(recipient, switched: countSwitch)
        stats.update {
            $0.poolConnected = false
            $0.job = JobStatistics()
            $0.state = .starting
            $0.lastError = nil
        }
        nextClient.connect()
        if recipient == .donation { startDonationTimeout() }
    }

    private func reconnectUser(after message: String) {
        condition.lock()
        guard !stopped, activeRecipient == .user else {
            condition.unlock()
            return
        }
        latestGeneration &+= 1
        latestHeight = nil
        queuedJob = nil
        condition.broadcast()
        let attempt = reconnectAttempt
        reconnectAttempt += 1
        condition.unlock()

        stats.update {
            $0.poolConnected = false
            $0.state = .reconnecting
            $0.reconnects += 1
            $0.lastError = message
        }
        emit("pool_disconnected", fieldsWithRecipient(.user, ["message": message]))
        let delay = min(30.0, pow(2.0, Double(min(attempt, 5))))
            + Double.random(in: 0...0.5)
        scheduleQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.condition.lock()
            let client = self.activeRecipient == .user && !self.stopped
                ? self.activeClient
                : nil
            self.condition.unlock()
            client?.connect()
        }
    }

    private func failDonation(reason: String) {
        condition.lock()
        guard !stopped,
              activeRecipient == .donation,
              !donationFailureInProgress
        else {
            condition.unlock()
            return
        }
        donationFailureInProgress = true
        let cycle = currentCycleIndex
        condition.unlock()

        stats.recordDonationFailure()
        emitDonationWindow("donation_window_failed", cycle: cycle, reason: reason)
        activate(
            .user,
            countSwitch: true,
            expectedCurrentRecipient: .donation)
    }

    private func startDonationTimeout() {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.condition.lock()
            let timedOut = !self.stopped
                && self.activeRecipient == .donation
                && !self.donationReady
            self.condition.unlock()
            if timedOut { self.failDonation(reason: "timeout") }
        }
        condition.lock()
        donationTimeoutWorkItem?.cancel()
        donationTimeoutWorkItem = work
        condition.unlock()
        scheduleQueue.asyncAfter(deadline: .now() + donationTimeoutSeconds, execute: work)
    }

    /// Called only while `condition` is locked.
    private func markDonationReadyIfPossible() {
        guard donationAuthorized, donationJobReceived else { return }
        donationReady = true
        donationTimeoutWorkItem?.cancel()
        donationTimeoutWorkItem = nil
    }

    private func scheduleNextBoundary() {
        condition.lock()
        guard !stopped, let startedAt = scheduleStartedAt else {
            condition.unlock()
            return
        }
        let elapsed = max(0, uptime() - startedAt)
        guard let nextBoundary = donationSchedule.nextBoundary(after: elapsed) else {
            condition.unlock()
            return
        }
        let delay = max(0, nextBoundary - elapsed)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.condition.lock()
            guard let startedAt = self.scheduleStartedAt, !self.stopped else {
                self.condition.unlock()
                return
            }
            let elapsed = max(0, self.uptime() - startedAt)
            self.condition.unlock()
            self.advanceSchedule(to: elapsed + 0.000_001)
            self.scheduleNextBoundary()
        }
        boundaryWorkItem?.cancel()
        boundaryWorkItem = work
        condition.unlock()
        scheduleQueue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func fieldsWithRecipient(
        _ recipient: MiningRecipient,
        _ fields: [String: String] = [:]
    ) -> [String: String] {
        var result = fields
        result["mining_recipient"] = recipient.rawValue
        return result
    }

    private func emitDonationWindow(
        _ type: String,
        cycle: Int,
        reason: String? = nil
    ) {
        var fields = [
            "cycle": String(cycle),
            "donation_percent": String(donationSchedule.percent)
        ]
        if let reason { fields["reason"] = reason }
        emit(type, fields)
    }

    private func emit(_ type: String, _ fields: [String: String] = [:]) {
        writer.write(MinerEvent(
            sessionID: stats.snapshot().sessionID,
            type: type,
            fields: fields))
    }
}
