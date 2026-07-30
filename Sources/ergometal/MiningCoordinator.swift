import Foundation
import MetalErgoCore

final class MiningCoordinator: @unchecked Sendable {
    let stats: StatisticsStore
    let writer: JSONLEventWriter
    private let condition = NSCondition()
    private var queuedJob: ErgoStratumJob?
    private var latestGeneration: UInt64 = 0
    private var latestHeight: Int?
    private var stopped = false
    private var stopFinalized = false
    private var reconnectAttempt = 0
    weak var client: ErgoStratumClient?

    init(stats: StatisticsStore, writer: JSONLEventWriter) {
        self.stats = stats; self.writer = writer
    }

    func handle(_ event: StratumEvent) {
        switch event {
        case .connected:
            stats.update { $0.poolConnected = true; $0.state = .starting; $0.lastError = nil }
            emit("pool_connected")
        case .authorized:
            reconnectAttempt = 0
            stats.update { $0.lastError = nil }
            emit("pool_authorized")
        case .difficulty(let value):
            stats.update { $0.job.difficulty = value }
        case .job(let job):
            condition.lock()
            latestGeneration = job.generation; latestHeight = job.height; queuedJob = job
            condition.broadcast(); condition.unlock()
            stats.update {
                $0.job = JobStatistics(
                    id: job.id,
                    height: job.height,
                    receivedAt: job.receivedAt,
                    difficulty: $0.job.difficulty,
                    targetHex: job.target.hex)
            }
            emit("job_received", [
                "id": job.id,
                "height": String(job.height),
                "job_target_hex": job.target.hex
            ])
        case .shareResult(_, let accepted, let message):
            stats.update { if accepted { $0.shares.accepted += 1 } else { $0.shares.rejected += 1 } }
            emit(accepted ? "share_accepted" : "share_rejected", message.map { ["reason": $0] } ?? [:])
        case .protocolError(let message):
            stats.update { $0.protocolErrors += 1; $0.lastError = message }
            emit("protocol_error", ["message": message])
        case .disconnected(let message):
            guard !isStopped else { return }
            condition.lock()
            latestGeneration &+= 1
            latestHeight = nil
            queuedJob = nil
            condition.broadcast()
            condition.unlock()
            stats.update { $0.poolConnected = false; $0.state = .reconnecting; $0.reconnects += 1; $0.lastError = message }
            emit("pool_disconnected", ["message": message])
            let delay = min(30.0, pow(2.0, Double(min(reconnectAttempt, 5)))) + Double.random(in: 0...0.5)
            reconnectAttempt += 1
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !self.isStopped else { return }; self.client?.connect()
            }
        }
    }

    func nextJob() -> ErgoStratumJob? {
        condition.lock(); defer { condition.unlock() }
        while queuedJob == nil && !stopped { condition.wait(until: Date(timeIntervalSinceNow: 1)) }
        let job = queuedJob; queuedJob = nil; return job
    }

    func isCurrent(_ job: ErgoStratumJob) -> Bool {
        condition.lock(); defer { condition.unlock() }
        return !stopped && latestGeneration == job.generation
    }

    func isHeightCurrent(_ height: Int) -> Bool {
        condition.lock(); defer { condition.unlock() }
        return !stopped && latestHeight == height
    }

    func isEitherHeightCurrent(_ first: Int, _ second: Int) -> Bool {
        condition.lock(); defer { condition.unlock() }
        return !stopped && (latestHeight == first || latestHeight == second)
    }

    var isStopped: Bool { condition.lock(); defer { condition.unlock() }; return stopped }

    func recordStatisticsSample() {
        condition.lock()
        guard !stopped else { condition.unlock(); return }
        let snapshot = stats.refresh()
        writer.write(MinerEvent(
            sessionID: snapshot.sessionID,
            type: "statistics_sample",
            fields: snapshot.eventFields))
        condition.unlock()
    }

    func stop() {
        condition.lock()
        if stopped {
            while !stopFinalized { condition.wait() }
            condition.unlock()
            return
        }
        stopped = true
        condition.broadcast()
        condition.unlock()
        client?.disconnect()
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

    private func emit(_ type: String, _ fields: [String: String] = [:]) {
        writer.write(MinerEvent(sessionID: stats.snapshot().sessionID, type: type, fields: fields))
    }
}
