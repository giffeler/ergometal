import Foundation
import MetalErgoCore

final class MiningCoordinator: @unchecked Sendable {
    let stats: StatisticsStore
    let writer: JSONLEventWriter
    private let condition = NSCondition()
    private var queuedJob: ErgoStratumJob?
    private var latestGeneration: UInt64 = 0
    private var stopped = false
    private var reconnectAttempt = 0
    weak var client: ErgoStratumClient?

    init(stats: StatisticsStore, writer: JSONLEventWriter) {
        self.stats = stats; self.writer = writer
    }

    func handle(_ event: StratumEvent) {
        switch event {
        case .connected:
            reconnectAttempt = 0
            stats.update { $0.poolConnected = true; $0.state = .starting }
            emit("pool_connected")
        case .authorized:
            emit("pool_authorized")
        case .difficulty(let value):
            stats.update { $0.job.difficulty = value }
        case .job(let job):
            condition.lock()
            latestGeneration = job.generation; queuedJob = job
            condition.broadcast(); condition.unlock()
            stats.update {
                $0.job = JobStatistics(id: job.id, height: job.height, receivedAt: job.receivedAt, difficulty: $0.job.difficulty)
            }
            emit("job_received", ["id": job.id, "height": String(job.height)])
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

    var isStopped: Bool { condition.lock(); defer { condition.unlock() }; return stopped }

    func stop() {
        condition.lock(); stopped = true; condition.broadcast(); condition.unlock()
        client?.disconnect()
        stats.update { $0.state = .stopped }
        emit("session_ended")
    }

    private func emit(_ type: String, _ fields: [String: String] = [:]) {
        writer.write(MinerEvent(sessionID: stats.snapshot().sessionID, type: type, fields: fields))
    }
}
