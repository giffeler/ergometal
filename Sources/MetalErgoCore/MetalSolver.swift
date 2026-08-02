import Foundation
import Metal

public enum MetalSolverError: Error, LocalizedError {
    case noDevice
    case functionMissing(String)
    case pipeline(String)
    case allocation(bytes: UInt64, available: UInt64)
    case commandEncoding
    case invalidHeight(Int)
    case invalidNonceCount(Int)
    case invalidNonceRange(base: UInt64, count: Int)
    case invalidThreadgroupSize(Int)
    case invalidDatasetChunkSize(Int)
    case resultOverflow(limit: Int, found: UInt32)
    case capture(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .noDevice: return "No Metal device is available"
        case .functionMissing(let name): return "Metal function '\(name)' is missing"
        case .pipeline(let message): return "Metal pipeline creation failed: \(message)"
        case .allocation(let bytes, let available):
            return "Autolykos dataset needs \(bytes) bytes plus headroom; recommended working set is \(available) bytes"
        case .commandEncoding: return "Could not create a Metal command buffer or encoder"
        case .invalidHeight(let height): return "Height must fit an unsigned 32-bit value, got \(height)"
        case .invalidNonceCount(let count): return "Nonce count must be positive, got \(count)"
        case .invalidNonceRange(let base, let count):
            return "Nonce range starting at \(base) with \(count) values exceeds UInt64"
        case .invalidThreadgroupSize(let size): return "Threadgroup size must be positive, got \(size)"
        case .invalidDatasetChunkSize(let size):
            return "Dataset chunk size must be positive, got \(size)"
        case .resultOverflow(let limit, let found):
            return "Metal candidate buffer can hold \(limit) nonces, but the batch found \(found)"
        case .capture(let message): return "Metal GPU capture failed: \(message)"
        case .cancelled: return "Metal dataset build was cancelled"
        }
    }
}

public struct MetalDeviceInfo: Codable, Sendable {
    public let name: String
    public let registryID: UInt64
    public let recommendedWorkingSetBytes: UInt64
    public let maxBufferBytes: UInt64
    public let unifiedMemory: Bool
}

public enum DatasetBuildSource: String, Codable, Sendable {
    case built
    case prefetched
    case cached
}

public enum DatasetKernel: String, CaseIterable, Codable, Sendable {
    case baseline
    case u32Pair = "u32pair"
    case u32PairInlineM = "u32pair-inline-m"

    fileprivate var functionName: String {
        switch self {
        case .baseline: return "buildDataset"
        case .u32Pair: return "buildDatasetU32Pair"
        case .u32PairInlineM: return "buildDatasetU32PairInlineM"
        }
    }
}

public enum SearchKernel: String, CaseIterable, Codable, Sendable {
    case search
    case gatherOnly = "gather-only"

    fileprivate var functionName: String {
        switch self {
        case .search: return "searchNonces"
        case .gatherOnly: return "gatherOnlyNonces"
        }
    }
}

public enum DatasetScheduling: String, CaseIterable, Codable, Sendable {
    case serialized
    case overlap
}

public struct DatasetWorkMetrics: Codable, Sendable, Equatable {
    public var coldBuildsCompleted = 0
    public var coldBuildsCancelled = 0
    public var coldBuildsFailed = 0
    public var coldBuildWallSeconds = 0.0
    public var coldBuildGPUSeconds = 0.0
    public var prefetchBuildsStarted = 0
    public var prefetchBuildsCompleted = 0
    public var prefetchBuildsCancelled = 0
    public var prefetchBuildsFailed = 0
    public var prefetchBuildsDiscarded = 0
    public var prefetchBuildWallSeconds = 0.0
    public var prefetchBuildGPUSeconds = 0.0
    public var prefetchWastedWallSeconds = 0.0
    public var prefetchWastedGPUSeconds = 0.0
    public var buildCommandsCompleted = 0
    public var buildCommandWallSeconds = 0.0
    public var buildCommandGPUSeconds = 0.0
    public var searchCommandsCompleted = 0
    public var searchCommandWallSeconds = 0.0
    public var searchCommandGPUSeconds = 0.0
    /// Unions of the overlapping search intervals. The summed fields above count
    /// each concurrently executing command separately, so at a pipeline depth
    /// above one they exceed the elapsed search window and cannot be read as
    /// utilization. Only these unions are comparable with wall time.
    public var searchCommandWallBusySeconds = 0.0
    public var searchCommandGPUBusySeconds = 0.0

    public init() {}
}

public struct DatasetBuild: Sendable {
    public let height: Int
    public let tableSize: Int
    public let bytes: UInt64
    public let seconds: Double
    public let gpuSeconds: Double
    public let activationSeconds: Double
    public let prefetchWaitSeconds: Double
    public let source: DatasetBuildSource

    public var waitedForPrefetch: Bool {
        source == .prefetched && prefetchWaitSeconds > 0
    }
}

public struct DatasetPrefetchStatus: Sendable {
    public let height: Int
    public let completedElements: Int
    public let tableSize: Int
    public let finished: Bool
    public let seconds: Double?
    public let gpuSeconds: Double?
    public let errorDescription: String?

    public var progress: Double {
        tableSize > 0 ? Double(completedElements) / Double(tableSize) : 0
    }
}

public struct SearchBatch: Sendable {
    public let baseNonce: UInt64
    public let nonceCount: Int
    public let candidates: [UInt64]
    /// Absolute system-uptime timestamps allow overlapping submissions to be
    /// merged without double-counting their active search window.
    public let wallStartTime: TimeInterval
    public let wallEndTime: TimeInterval
    public let gpuSeconds: Double
    public let wallSeconds: Double
}

/// A queued Metal search. Waiting is deliberately separate from submission so
/// callers can keep the next command buffer ready while processing the current
/// batch on the CPU.
public final class SearchSubmission: @unchecked Sendable {
    public let baseNonce: UInt64
    public let nonceCount: Int

    private let condition = NSCondition()
    private var result: Result<SearchBatch, Error>?

    fileprivate init(baseNonce: UInt64, nonceCount: Int) {
        self.baseNonce = baseNonce
        self.nonceCount = nonceCount
    }

    fileprivate func resolve(_ result: Result<SearchBatch, Error>) {
        condition.lock()
        guard self.result == nil else {
            condition.unlock()
            return
        }
        self.result = result
        condition.broadcast()
        condition.unlock()
    }

    public func wait() throws -> SearchBatch {
        condition.lock()
        while result == nil { condition.wait() }
        let result = self.result!
        condition.unlock()
        return try result.get()
    }
}

private final class DatasetBuildSubmission: @unchecked Sendable {
    private let condition = NSCondition()
    private var result: Result<Double, Error>?

    func resolve(_ result: Result<Double, Error>) {
        condition.lock()
        guard self.result == nil else {
            condition.unlock()
            return
        }
        self.result = result
        condition.broadcast()
        condition.unlock()
    }

    func result(until deadline: Date) -> Result<Double, Error>? {
        condition.lock()
        if result == nil { condition.wait(until: deadline) }
        let result = self.result
        condition.unlock()
        return result
    }

    func wait() throws -> Double {
        condition.lock()
        while result == nil { condition.wait() }
        let result = self.result!
        condition.unlock()
        return try result.get()
    }
}

private struct PendingDatasetBuild {
    let submission: DatasetBuildSubmission
    let elementCount: Int
}

/// Tracks the union of submission-to-completion intervals. Summing individual
/// command latencies would double-count the two pipelined commands and corrupt
/// the existing wall-minus-GPU overhead metric.
private final class DatasetBuildWallAccumulator: @unchecked Sendable {
    private struct Interval {
        var start: TimeInterval
        var end: TimeInterval
    }

    private let lock = NSLock()
    private var intervals: [Interval] = []

    func record(start: TimeInterval, end: TimeInterval) -> Double {
        let lowerBound = min(start, end)
        let upperBound = max(start, end)
        lock.lock(); defer { lock.unlock() }

        var mergedStart = lowerBound
        var mergedEnd = upperBound
        var overlap = 0.0
        var retained: [Interval] = []
        retained.reserveCapacity(intervals.count + 1)
        for interval in intervals {
            if interval.end < mergedStart || interval.start > mergedEnd {
                retained.append(interval)
            } else {
                overlap += max(
                    0,
                    min(upperBound, interval.end) - max(lowerBound, interval.start))
                mergedStart = min(mergedStart, interval.start)
                mergedEnd = max(mergedEnd, interval.end)
            }
        }
        retained.append(Interval(start: mergedStart, end: mergedEnd))
        intervals = retained
        return max(0, upperBound - lowerBound - overlap)
    }
}

private final class CommandIntervalUnion: @unchecked Sendable {
    private struct Interval {
        var start: TimeInterval
        var end: TimeInterval
    }

    private static let maximumLiveIntervals = 8

    private let lock = NSLock()
    private var live: [Interval] = []

    func record(start: TimeInterval, end: TimeInterval) -> Double {
        let lowerBound = min(start, end)
        let upperBound = max(start, end)
        lock.lock(); defer { lock.unlock() }

        var mergedStart = lowerBound
        var mergedEnd = upperBound
        var overlap = 0.0
        var retained: [Interval] = []
        retained.reserveCapacity(live.count + 1)
        for interval in live {
            if interval.end < mergedStart || interval.start > mergedEnd {
                retained.append(interval)
            } else {
                overlap += max(
                    0,
                    min(upperBound, interval.end) - max(lowerBound, interval.start))
                mergedStart = min(mergedStart, interval.start)
                mergedEnd = max(mergedEnd, interval.end)
            }
        }
        retained.append(Interval(start: mergedStart, end: mergedEnd))
        // Only intervals that can still overlap a future submission need to stay
        // live; pipeline depth is small, so this stays at a few entries across
        // millions of commands instead of growing O(n) per run.
        if retained.count > Self.maximumLiveIntervals {
            retained.sort { $0.start < $1.start }
            retained.removeFirst(retained.count - Self.maximumLiveIntervals)
        }
        live = retained
        return max(0, upperBound - lowerBound - overlap)
    }
}

private final class MetalBundleToken {}

/// FIFO admission prevents either the dataset worker or the search loop from
/// repeatedly reacquiring the GPU while the other side is already waiting.
private final class MetalCommandGate {
    private let condition = NSCondition()
    private var nextTicket: UInt64 = 0
    private var servingTicket: UInt64 = 0

    func enter() {
        condition.lock()
        let ticket = nextTicket
        nextTicket &+= 1
        while ticket != servingTicket { condition.wait() }
        condition.unlock()
    }

    func leave() {
        condition.lock()
        servingTicket &+= 1
        condition.broadcast()
        condition.unlock()
    }
}

private struct SearchModuloParameters {
    let reciprocal64: UInt64
    let reciprocal32: UInt32
    let padding: UInt32 = 0

    init(tableSize: UInt32) {
        guard tableSize > 1 else {
            reciprocal64 = 0
            reciprocal32 = 0
            return
        }
        let divisor = UInt64(tableSize)
        let quotient = UInt64.max / divisor
        let remainder = UInt64.max % divisor
        // floor(2^64 / divisor), expressed without constructing 2^64.
        reciprocal64 = quotient + (remainder == divisor - 1 ? 1 : 0)
        reciprocal32 = UInt32((UInt64(1) << 32) / divisor)
    }
}

private struct DatasetSpec {
    let height: Int
    let tableSize: Int
    let bytes: UInt64
    let searchModulo: SearchModuloParameters

    func matches(height: Int, tableSize: Int) -> Bool {
        self.height == height && self.tableSize == tableSize
    }
}

private final class DatasetSlot {
    let spec: DatasetSpec
    let buffer: MTLBuffer
    var buildSeconds: Double = 0
    var buildGPUSeconds: Double = 0

    init(spec: DatasetSpec, buffer: MTLBuffer) {
        self.spec = spec
        self.buffer = buffer
    }
}

private final class DatasetPrefetchTask {
    let slot: DatasetSlot
    let started = ContinuousClock.now
    var completedElements = 0
    var finished = false
    var cancelled = false
    var discarded = false
    var failure: Error?

    init(slot: DatasetSlot) {
        self.slot = slot
    }
}

private final class SearchResources {
    let resultBuffer: MTLBuffer
    let resultCountBuffer: MTLBuffer
    var inUse = false

    init(resultBuffer: MTLBuffer, resultCountBuffer: MTLBuffer) {
        self.resultBuffer = resultBuffer
        self.resultCountBuffer = resultCountBuffer
    }
}

public final class MetalAutolykosSolver {
    private static let maximumResults = 256
    private static let searchPipelineDepth = 2
    private static let buildPipelineDepth = 2
    public static let defaultSynchronousBuildChunkElements = 2_097_152
    public static let defaultPrefetchBuildChunkElements = 1_048_576

    public let device: MTLDevice
    public let info: MetalDeviceInfo
    public let datasetKernel: DatasetKernel
    public let datasetScheduling: DatasetScheduling
    public let searchKernel: SearchKernel
    private let searchCommandQueue: MTLCommandQueue
    private let buildCommandQueue: MTLCommandQueue
    private let buildPipeline: MTLComputePipelineState
    private let searchPipeline: MTLComputePipelineState
    private let constantMBuffer: MTLBuffer
    private let searchResources: [SearchResources]
    private let searchResourceState = NSCondition()
    private let searchWallUnion = CommandIntervalUnion()
    private let searchGPUUnion = CommandIntervalUnion()
    private let buildCommandSlots = DispatchSemaphore(value: buildPipelineDepth)
    private let commandGate = MetalCommandGate()
    private let state = NSCondition()
    private let prefetchWorker = DispatchQueue(label: "dev.ergometal.dataset-prefetch", qos: .userInitiated)
    private let synchronousBuildChunkElements: Int
    private let prefetchBuildChunkElements: Int
    private let datasetThreadgroupSize: Int
    private var activeDataset: DatasetSlot?
    private var prefetchTask: DatasetPrefetchTask?
    private var workMetrics = DatasetWorkMetrics()

    public init(
        device: MTLDevice? = MTLCreateSystemDefaultDevice(),
        synchronousBuildChunkElements: Int = MetalAutolykosSolver.defaultSynchronousBuildChunkElements,
        prefetchBuildChunkElements: Int = MetalAutolykosSolver.defaultPrefetchBuildChunkElements,
        datasetThreadgroupSize: Int = 256,
        datasetKernel: DatasetKernel = .u32PairInlineM,
        datasetScheduling: DatasetScheduling = .overlap,
        searchKernel: SearchKernel = .search
    ) throws {
        guard synchronousBuildChunkElements > 0 else {
            throw MetalSolverError.invalidDatasetChunkSize(synchronousBuildChunkElements)
        }
        guard prefetchBuildChunkElements > 0 else {
            throw MetalSolverError.invalidDatasetChunkSize(prefetchBuildChunkElements)
        }
        guard datasetThreadgroupSize > 0 else {
            throw MetalSolverError.invalidThreadgroupSize(datasetThreadgroupSize)
        }
        guard let device else { throw MetalSolverError.noDevice }
        guard let searchCommandQueue = device.makeCommandQueue(),
              let constantMBuffer = device.makeBuffer(
                length: 1_024 * MemoryLayout<UInt64>.size,
                options: .storageModeShared)
        else { throw MetalSolverError.noDevice }
        let buildCommandQueue: MTLCommandQueue
        if datasetScheduling == .overlap {
            guard let queue = device.makeCommandQueue() else { throw MetalSolverError.noDevice }
            buildCommandQueue = queue
        } else {
            buildCommandQueue = searchCommandQueue
        }
        var searchResources: [SearchResources] = []
        for _ in 0..<Self.searchPipelineDepth {
            guard let resultBuffer = device.makeBuffer(
                    length: Self.maximumResults * MemoryLayout<UInt64>.size,
                    options: .storageModeShared),
                  let resultCountBuffer = device.makeBuffer(
                    length: MemoryLayout<UInt32>.size,
                    options: .storageModeShared)
            else { throw MetalSolverError.noDevice }
            searchResources.append(SearchResources(
                resultBuffer: resultBuffer, resultCountBuffer: resultCountBuffer))
        }
        self.device = device
        self.datasetKernel = datasetKernel
        self.datasetScheduling = datasetScheduling
        self.searchKernel = searchKernel
        self.searchCommandQueue = searchCommandQueue
        self.buildCommandQueue = buildCommandQueue
        self.constantMBuffer = constantMBuffer
        self.searchResources = searchResources
        self.synchronousBuildChunkElements = synchronousBuildChunkElements
        self.prefetchBuildChunkElements = prefetchBuildChunkElements
        self.datasetThreadgroupSize = datasetThreadgroupSize
        self.info = MetalDeviceInfo(
            name: device.name,
            registryID: device.registryID,
            recommendedWorkingSetBytes: device.recommendedMaxWorkingSetSize,
            maxBufferBytes: UInt64(device.maxBufferLength),
            unifiedMemory: device.hasUnifiedMemory
        )
        let constantM = constantMBuffer.contents().bindMemory(to: UInt64.self, capacity: 1_024)
        for index in 0..<1_024 {
            constantM[index] = UInt64(index).bigEndian
        }

        let library: MTLLibrary
        do {
            library = try device.makeDefaultLibrary(bundle: Bundle(for: MetalBundleToken.self))
        } catch {
            throw MetalSolverError.pipeline(error.localizedDescription)
        }
        guard let build = library.makeFunction(name: datasetKernel.functionName) else {
            throw MetalSolverError.functionMissing(datasetKernel.functionName)
        }
        guard let search = library.makeFunction(name: searchKernel.functionName) else {
            throw MetalSolverError.functionMissing(searchKernel.functionName)
        }
        do {
            buildPipeline = try device.makeComputePipelineState(function: build)
            searchPipeline = try device.makeComputePipelineState(function: search)
        } catch {
            throw MetalSolverError.pipeline(error.localizedDescription)
        }
    }

    public static func devices() -> [MetalDeviceInfo] {
        MTLCopyAllDevices().map {
            MetalDeviceInfo(name: $0.name, registryID: $0.registryID,
                recommendedWorkingSetBytes: $0.recommendedMaxWorkingSetSize,
                maxBufferBytes: UInt64($0.maxBufferLength), unifiedMemory: $0.hasUnifiedMemory)
        }
    }

    public func startGPUCapture(path: String) throws {
        let manager = MTLCaptureManager.shared()
        guard !manager.isCapturing else {
            throw MetalSolverError.capture("another capture is already active")
        }
        guard manager.supportsDestination(.gpuTraceDocument) else {
            throw MetalSolverError.capture("GPU trace documents are not supported")
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.pathExtension == "gputrace" else {
            throw MetalSolverError.capture("output path must end in .gputrace")
        }
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw MetalSolverError.capture("output file already exists at \(url.path)")
        }
        let descriptor = MTLCaptureDescriptor()
        descriptor.captureObject = device
        descriptor.destination = .gpuTraceDocument
        descriptor.outputURL = url
        do {
            try manager.startCapture(with: descriptor)
        } catch {
            throw MetalSolverError.capture(error.localizedDescription)
        }
    }

    public func stopGPUCapture() {
        let manager = MTLCaptureManager.shared()
        if manager.isCapturing { manager.stopCapture() }
    }

    @discardableResult
    public func buildDataset(
        height: Int,
        tableSize override: Int? = nil,
        shouldContinue: (() -> Bool)? = nil
    ) throws -> DatasetBuild {
        let spec = try datasetSpec(height: height, tableSize: override)
        let activationStarted = ContinuousClock.now

        state.lock()
        if let activeDataset, activeDataset.spec.matches(height: height, tableSize: spec.tableSize) {
            let seconds = activeDataset.buildSeconds
            state.unlock()
            return DatasetBuild(
                height: height, tableSize: spec.tableSize, bytes: spec.bytes, seconds: seconds,
                gpuSeconds: activeDataset.buildGPUSeconds,
                activationSeconds: activationStarted.duration(to: .now).seconds,
                prefetchWaitSeconds: 0, source: .cached)
        }
        state.unlock()

        if let prefetched = try takePrefetchedDataset(spec: spec, shouldContinue: shouldContinue) {
            return DatasetBuild(
                height: height, tableSize: spec.tableSize, bytes: spec.bytes,
                seconds: prefetched.slot.buildSeconds,
                gpuSeconds: prefetched.slot.buildGPUSeconds,
                activationSeconds: activationStarted.duration(to: .now).seconds,
                prefetchWaitSeconds: prefetched.waitSeconds,
                source: .prefetched)
        }

        state.lock()
        activeDataset = nil
        state.unlock()
        try validateWorkingSet(bytes: [spec.bytes])
        guard let buffer = device.makeBuffer(length: Int(spec.bytes), options: .storageModePrivate)
        else { throw MetalSolverError.allocation(bytes: spec.bytes, available: info.recommendedWorkingSetBytes) }
        let slot = DatasetSlot(spec: spec, buffer: buffer)
        let timing = try buildSynchronously(slot: slot, shouldContinue: shouldContinue)
        slot.buildSeconds = timing.wallSeconds
        slot.buildGPUSeconds = timing.gpuSeconds
        state.lock()
        activeDataset = slot
        state.unlock()
        return DatasetBuild(
            height: height, tableSize: spec.tableSize, bytes: spec.bytes,
            seconds: slot.buildSeconds, gpuSeconds: slot.buildGPUSeconds,
            activationSeconds: activationStarted.duration(to: .now).seconds,
            prefetchWaitSeconds: 0,
            source: .built)
    }

    /// Builds the next height in short command-buffer slices while the active
    /// dataset remains available between slices for nonce searches.
    @discardableResult
    public func prefetchDataset(height: Int, tableSize override: Int? = nil) throws -> Bool {
        let spec = try datasetSpec(height: height, tableSize: override)

        state.lock()
        if let activeDataset, activeDataset.spec.matches(height: height, tableSize: spec.tableSize) {
            state.unlock()
            return false
        }
        if let task = prefetchTask {
            if task.slot.spec.matches(height: height, tableSize: spec.tableSize), !task.cancelled {
                state.unlock()
                return false
            }
            if !task.finished {
                task.cancelled = true
                state.broadcast()
                state.unlock()
                return false
            }
            recordDiscardedPrefetchLocked(task)
            prefetchTask = nil
        }
        let activeBytes = activeDataset?.spec.bytes ?? 0
        state.unlock()

        try validateWorkingSet(bytes: [activeBytes, spec.bytes].filter { $0 > 0 })
        guard let buffer = device.makeBuffer(length: Int(spec.bytes), options: .storageModePrivate)
        else { throw MetalSolverError.allocation(bytes: activeBytes + spec.bytes, available: info.recommendedWorkingSetBytes) }
        let task = DatasetPrefetchTask(slot: DatasetSlot(spec: spec, buffer: buffer))

        state.lock()
        guard prefetchTask == nil else {
            state.unlock()
            return false
        }
        prefetchTask = task
        workMetrics.prefetchBuildsStarted += 1
        state.unlock()
        prefetchWorker.async { [weak self, task] in self?.runPrefetch(task) }
        return true
    }

    public func prefetchStatus() -> DatasetPrefetchStatus? {
        state.lock(); defer { state.unlock() }
        guard let task = prefetchTask, !task.cancelled else { return nil }
        return DatasetPrefetchStatus(
            height: task.slot.spec.height,
            completedElements: task.completedElements,
            tableSize: task.slot.spec.tableSize,
            finished: task.finished,
            seconds: task.finished && task.failure == nil ? task.slot.buildSeconds : nil,
            gpuSeconds: task.finished && task.failure == nil ? task.slot.buildGPUSeconds : nil,
            errorDescription: task.failure?.localizedDescription)
    }

    public func cancelPrefetch(waitUntilFinished: Bool = false) {
        state.lock()
        if let task = prefetchTask {
            if task.finished {
                recordDiscardedPrefetchLocked(task)
            } else {
                task.cancelled = true
            }
        }
        state.broadcast()
        while waitUntilFinished, let task = prefetchTask, !task.finished {
            state.wait(until: Date(timeIntervalSinceNow: 0.05))
        }
        state.unlock()
    }

    public func datasetWorkMetrics() -> DatasetWorkMetrics {
        state.lock(); defer { state.unlock() }
        return workMetrics
    }

    /// Copies selected elements from the private active dataset for exact
    /// consensus verification without making the mining buffer CPU-visible.
    public func datasetElements(at indices: [Int]) throws -> [UInt256] {
        guard !indices.isEmpty else { return [] }
        state.lock()
        let dataset = activeDataset
        state.unlock()
        guard let dataset else { throw MetalSolverError.commandEncoding }
        for index in indices where index < 0 || index >= dataset.spec.tableSize {
            throw AutolykosError.invalidDatasetIndex(index)
        }
        let elementBytes = 8 * MemoryLayout<UInt32>.size
        guard let staging = device.makeBuffer(
            length: indices.count * elementBytes,
            options: .storageModeShared)
        else { throw MetalSolverError.allocation(
            bytes: UInt64(indices.count * elementBytes),
            available: info.recommendedWorkingSetBytes) }

        enterSerializedGate(); defer { leaveSerializedGate() }
        guard let command = searchCommandQueue.makeCommandBufferWithUnretainedReferences(),
              let encoder = command.makeBlitCommandEncoder()
        else { throw MetalSolverError.commandEncoding }
        for (destination, index) in indices.enumerated() {
            encoder.copy(
                from: dataset.buffer,
                sourceOffset: index * elementBytes,
                to: staging,
                destinationOffset: destination * elementBytes,
                size: elementBytes)
        }
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        if let error = command.error {
            throw MetalSolverError.pipeline(error.localizedDescription)
        }
        let words = staging.contents().bindMemory(
            to: UInt32.self, capacity: indices.count * 8)
        return (0..<indices.count).map { element in
            UInt256(limbs: (0..<8).map { words[element * 8 + $0] })
        }
    }

    public func search(
        message: [UInt8], target: UInt256, baseNonce: UInt64, nonceCount: Int,
        threadgroupSize requested: Int? = nil
    ) throws -> SearchBatch {
        try enqueueSearch(
            message: message, target: target, baseNonce: baseNonce,
            nonceCount: nonceCount, threadgroupSize: requested
        ).wait()
    }

    /// Encodes and commits a search without waiting for it. Two independent
    /// result-buffer pairs allow one batch to execute while the preceding
    /// result is copied and verified on the CPU.
    public func enqueueSearch(
        message: [UInt8], target: UInt256, baseNonce: UInt64, nonceCount: Int,
        threadgroupSize requested: Int? = nil
    ) throws -> SearchSubmission {
        guard message.count == 32 else { throw AutolykosError.invalidMessageLength(message.count) }
        guard nonceCount > 0, UInt32(exactly: nonceCount) != nil else {
            throw MetalSolverError.invalidNonceCount(nonceCount)
        }
        guard UInt64(nonceCount - 1) <= UInt64.max - baseNonce else {
            throw MetalSolverError.invalidNonceRange(base: baseNonce, count: nonceCount)
        }
        if let requested, requested <= 0 { throw MetalSolverError.invalidThreadgroupSize(requested) }
        state.lock()
        let dataset = activeDataset
        state.unlock()
        guard let dataset else { throw MetalSolverError.commandEncoding }
        let messageWords = UInt256(bigEndian: message).limbs
        let targetWords = target.limbs
        let resources = acquireSearchResources()

        enterSerializedGate()
        guard let command = searchCommandQueue.makeCommandBufferWithUnretainedReferences(),
              let encoder = command.makeComputeCommandEncoder()
        else {
            leaveSerializedGate()
            releaseSearchResources(resources)
            throw MetalSolverError.commandEncoding
        }
        command.label = searchKernel.functionName
        encoder.label = searchKernel.functionName
        resources.resultCountBuffer.contents().storeBytes(of: UInt32(0), as: UInt32.self)

        var base = baseNonce
        var n = UInt32(dataset.spec.tableSize)
        var modulo = dataset.spec.searchModulo
        let pipeline = searchPipeline
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(dataset.buffer, offset: 0, index: 0)
        messageWords.withUnsafeBytes {
            encoder.setBytes($0.baseAddress!, length: $0.count, index: 1)
        }
        targetWords.withUnsafeBytes {
            encoder.setBytes($0.baseAddress!, length: $0.count, index: 2)
        }
        encoder.setBuffer(resources.resultBuffer, offset: 0, index: 3)
        encoder.setBuffer(resources.resultCountBuffer, offset: 0, index: 4)
        encoder.setBytes(&base, length: MemoryLayout<UInt64>.size, index: 5)
        encoder.setBytes(&n, length: MemoryLayout<UInt32>.size, index: 6)
        encoder.setBytes(
            &modulo, length: MemoryLayout<SearchModuloParameters>.stride, index: 7)
        let width = min(requested ?? 128, searchPipeline.maxTotalThreadsPerThreadgroup)
        encoder.dispatchThreads(MTLSize(width: nonceCount, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
        encoder.endEncoding()

        let submission = SearchSubmission(baseNonce: baseNonce, nonceCount: nonceCount)
        let wallStartTime = ProcessInfo.processInfo.systemUptime
        command.addCompletedHandler {
            [weak self, dataset, resources, submission, pipeline] command in
            // Unretained command buffers avoid per-batch driver retain traffic;
            // keep every referenced Metal object alive until completion here.
            _ = dataset
            _ = pipeline
            let result: Result<SearchBatch, Error>
            if let error = command.error {
                result = .failure(MetalSolverError.pipeline(error.localizedDescription))
            } else {
                let rawResultCount = resources.resultCountBuffer.contents().load(as: UInt32.self)
                if rawResultCount > Self.maximumResults {
                    result = .failure(MetalSolverError.resultOverflow(
                        limit: Self.maximumResults, found: rawResultCount))
                } else {
                    let resultCount = Int(rawResultCount)
                    let pointer = resources.resultBuffer.contents().bindMemory(
                        to: UInt64.self, capacity: Self.maximumResults)
                    let candidates = (0..<resultCount).map { pointer[$0] }.sorted()
                    let wallEndTime = ProcessInfo.processInfo.systemUptime
                    result = .success(SearchBatch(
                        baseNonce: baseNonce,
                        nonceCount: nonceCount,
                        candidates: candidates,
                        wallStartTime: wallStartTime,
                        wallEndTime: wallEndTime,
                        gpuSeconds: max(0, command.gpuEndTime - command.gpuStartTime),
                        wallSeconds: max(0, wallEndTime - wallStartTime)))
                }
            }
            if case .success(let batch) = result {
                self?.recordSearchCommand(
                    wallSeconds: batch.wallSeconds,
                    gpuSeconds: batch.gpuSeconds,
                    wallStart: batch.wallStartTime,
                    wallEnd: batch.wallEndTime,
                    gpuStart: command.gpuStartTime,
                    gpuEnd: command.gpuEndTime)
            }
            self?.releaseSearchResources(resources)
            submission.resolve(result)
        }
        command.commit()
        leaveSerializedGate()
        return submission
    }

    private func enterSerializedGate() {
        if datasetScheduling == .serialized { commandGate.enter() }
    }

    private func leaveSerializedGate() {
        if datasetScheduling == .serialized { commandGate.leave() }
    }

    private func acquireSearchResources() -> SearchResources {
        searchResourceState.lock()
        while true {
            if let resources = searchResources.first(where: { !$0.inUse }) {
                resources.inUse = true
                searchResourceState.unlock()
                return resources
            }
            searchResourceState.wait()
        }
    }

    private func releaseSearchResources(_ resources: SearchResources) {
        searchResourceState.lock()
        resources.inUse = false
        searchResourceState.signal()
        searchResourceState.unlock()
    }

    private func datasetSpec(height: Int, tableSize override: Int?) throws -> DatasetSpec {
        guard UInt32(exactly: height) != nil else { throw MetalSolverError.invalidHeight(height) }
        let tableSize = override ?? AutolykosV2.calcN(height: height)
        guard tableSize > 0, UInt32(exactly: tableSize) != nil else {
            throw AutolykosError.invalidTableSize(tableSize)
        }
        let (bytes, overflow) = UInt64(tableSize).multipliedReportingOverflow(by: 32)
        guard !overflow, bytes <= UInt64(device.maxBufferLength), Int(exactly: bytes) != nil else {
            throw MetalSolverError.allocation(bytes: bytes, available: info.recommendedWorkingSetBytes)
        }
        return DatasetSpec(
            height: height,
            tableSize: tableSize,
            bytes: bytes,
            searchModulo: SearchModuloParameters(tableSize: UInt32(tableSize)))
    }

    private func validateWorkingSet(bytes values: [UInt64]) throws {
        var total: UInt64 = 0
        for value in values {
            let (sum, overflow) = total.addingReportingOverflow(value)
            guard !overflow else {
                throw MetalSolverError.allocation(bytes: .max, available: info.recommendedWorkingSetBytes)
            }
            total = sum
        }
        let headroom = max(UInt64(512 * 1024 * 1024), total / 10)
        let (required, overflow) = total.addingReportingOverflow(headroom)
        guard !overflow, required <= info.recommendedWorkingSetBytes else {
            throw MetalSolverError.allocation(bytes: total, available: info.recommendedWorkingSetBytes)
        }
    }

    private func takePrefetchedDataset(
        spec: DatasetSpec,
        shouldContinue: (() -> Bool)?
    ) throws -> (slot: DatasetSlot, waitSeconds: Double)? {
        state.lock()
        guard let task = prefetchTask else {
            state.unlock()
            return nil
        }
        guard task.slot.spec.matches(height: spec.height, tableSize: spec.tableSize) else {
            if task.finished {
                recordDiscardedPrefetchLocked(task)
            } else {
                task.cancelled = true
            }
            state.broadcast()
            while !task.finished {
                if shouldContinue?() == false {
                    state.unlock()
                    throw MetalSolverError.cancelled
                }
                state.wait(until: Date(timeIntervalSinceNow: 0.05))
            }
            prefetchTask = nil
            state.unlock()
            return nil
        }
        let waitStarted = ContinuousClock.now
        let hadToWait = !task.finished
        while !task.finished {
            if shouldContinue?() == false {
                task.cancelled = true
                state.broadcast()
                state.unlock()
                throw MetalSolverError.cancelled
            }
            state.wait(until: Date(timeIntervalSinceNow: 0.05))
        }
        guard !task.cancelled, task.failure == nil else {
            prefetchTask = nil
            state.unlock()
            return nil
        }
        activeDataset = task.slot
        prefetchTask = nil
        state.unlock()
        return (task.slot, hadToWait ? waitStarted.duration(to: .now).seconds : 0)
    }

    private struct DatasetBuildTiming {
        let wallSeconds: Double
        let gpuSeconds: Double
    }

    private func buildSynchronously(
        slot: DatasetSlot,
        shouldContinue: (() -> Bool)?
    ) throws -> DatasetBuildTiming {
        let started = ContinuousClock.now
        var nextIndex = 0
        var gpuSeconds = 0.0
        var pending: [PendingDatasetBuild] = []
        var failure: Error?
        let wallAccumulator = DatasetBuildWallAccumulator()

        while nextIndex < slot.spec.tableSize, failure == nil {
            guard shouldContinue?() != false else {
                failure = MetalSolverError.cancelled
                break
            }
            if pending.count == Self.buildPipelineDepth {
                do {
                    gpuSeconds += try waitForBuildSubmission(
                        pending[0].submission, shouldContinue: shouldContinue)
                    pending.removeFirst()
                } catch {
                    failure = error
                }
                continue
            }
            let count = min(synchronousBuildChunkElements, slot.spec.tableSize - nextIndex)
            do {
                pending.append(PendingDatasetBuild(
                    submission: try enqueueBuildChunk(
                        slot: slot,
                        startIndex: nextIndex,
                        count: count,
                        wallAccumulator: wallAccumulator),
                    elementCount: count))
                nextIndex += count
            } catch {
                failure = error
            }
        }

        while !pending.isEmpty, failure == nil {
            do {
                gpuSeconds += try waitForBuildSubmission(
                    pending[0].submission, shouldContinue: shouldContinue)
                pending.removeFirst()
            } catch {
                failure = error
            }
        }
        // Submitted Metal work cannot be cancelled. Drain it before releasing
        // the dataset slot so timing, counters, and unretained resources remain valid.
        while !pending.isEmpty {
            let chunk = pending.removeFirst()
            do {
                gpuSeconds += try chunk.submission.wait()
            } catch {
                if failure == nil { failure = error }
            }
        }

        if let failure {
            let wallSeconds = started.duration(to: .now).seconds
            state.lock()
            if case MetalSolverError.cancelled = failure {
                workMetrics.coldBuildsCancelled += 1
            } else {
                workMetrics.coldBuildsFailed += 1
            }
            workMetrics.coldBuildWallSeconds += wallSeconds
            workMetrics.coldBuildGPUSeconds += gpuSeconds
            state.unlock()
            throw failure
        }
        let wallSeconds = started.duration(to: .now).seconds
        state.lock()
        workMetrics.coldBuildsCompleted += 1
        workMetrics.coldBuildWallSeconds += wallSeconds
        workMetrics.coldBuildGPUSeconds += gpuSeconds
        state.unlock()
        return DatasetBuildTiming(wallSeconds: wallSeconds, gpuSeconds: gpuSeconds)
    }

    private func runPrefetch(_ task: DatasetPrefetchTask) {
        var nextIndex = 0
        var pending: [PendingDatasetBuild] = []
        var failure: Error?
        let wallAccumulator = DatasetBuildWallAccumulator()

        while nextIndex < task.slot.spec.tableSize, failure == nil {
            guard prefetchShouldContinue(task) else {
                failure = MetalSolverError.cancelled
                break
            }
            if pending.count == Self.buildPipelineDepth {
                do {
                    let chunk = pending[0]
                    let gpuSeconds = try waitForBuildSubmission(
                        chunk.submission,
                        shouldContinue: { [weak self, task] in
                            self?.prefetchShouldContinue(task) ?? false
                        })
                    pending.removeFirst()
                    recordCompletedPrefetchChunk(task, chunk: chunk, gpuSeconds: gpuSeconds)
                } catch {
                    failure = error
                }
                continue
            }
            let count = min(
                prefetchBuildChunkElements,
                task.slot.spec.tableSize - nextIndex)
            do {
                pending.append(PendingDatasetBuild(
                    submission: try enqueueBuildChunk(
                        slot: task.slot,
                        startIndex: nextIndex,
                        count: count,
                        wallAccumulator: wallAccumulator),
                    elementCount: count))
                nextIndex += count
            } catch {
                failure = error
            }
        }

        while !pending.isEmpty, failure == nil {
            do {
                let chunk = pending[0]
                let gpuSeconds = try waitForBuildSubmission(
                    chunk.submission,
                    shouldContinue: { [weak self, task] in
                        self?.prefetchShouldContinue(task) ?? false
                    })
                pending.removeFirst()
                recordCompletedPrefetchChunk(task, chunk: chunk, gpuSeconds: gpuSeconds)
            } catch {
                failure = error
            }
        }
        while !pending.isEmpty {
            let chunk = pending.removeFirst()
            do {
                let gpuSeconds = try chunk.submission.wait()
                recordCompletedPrefetchChunk(task, chunk: chunk, gpuSeconds: gpuSeconds)
            } catch {
                if failure == nil { failure = error }
            }
        }

        if let failure {
            state.lock()
            task.failure = failure
            state.unlock()
        } else {
            task.slot.buildSeconds = task.started.duration(to: .now).seconds
        }
        state.lock()
        let wallSeconds = task.started.duration(to: .now).seconds
        let cancelledFailure: Bool
        if let failure = task.failure as? MetalSolverError, case .cancelled = failure {
            cancelledFailure = true
        } else {
            cancelledFailure = false
        }
        if task.cancelled || cancelledFailure {
            workMetrics.prefetchBuildsCancelled += 1
            workMetrics.prefetchWastedWallSeconds += wallSeconds
            workMetrics.prefetchWastedGPUSeconds += task.slot.buildGPUSeconds
        } else if task.failure != nil {
            workMetrics.prefetchBuildsFailed += 1
            workMetrics.prefetchWastedWallSeconds += wallSeconds
            workMetrics.prefetchWastedGPUSeconds += task.slot.buildGPUSeconds
        } else {
            workMetrics.prefetchBuildsCompleted += 1
            workMetrics.prefetchBuildWallSeconds += wallSeconds
            workMetrics.prefetchBuildGPUSeconds += task.slot.buildGPUSeconds
        }
        task.finished = true
        state.broadcast()
        state.unlock()
    }

    private func prefetchShouldContinue(_ task: DatasetPrefetchTask) -> Bool {
        state.lock(); defer { state.unlock() }
        return !task.cancelled
    }

    private func recordCompletedPrefetchChunk(
        _ task: DatasetPrefetchTask,
        chunk: PendingDatasetBuild,
        gpuSeconds: Double
    ) {
        state.lock()
        task.slot.buildGPUSeconds += gpuSeconds
        task.completedElements += chunk.elementCount
        state.broadcast()
        state.unlock()
    }

    private func recordDiscardedPrefetchLocked(_ task: DatasetPrefetchTask) {
        guard task.finished, task.failure == nil, !task.discarded else { return }
        task.discarded = true
        workMetrics.prefetchBuildsDiscarded += 1
        workMetrics.prefetchWastedWallSeconds += task.slot.buildSeconds
        workMetrics.prefetchWastedGPUSeconds += task.slot.buildGPUSeconds
    }

    private func recordSearchCommand(
        wallSeconds: Double,
        gpuSeconds: Double,
        wallStart: TimeInterval,
        wallEnd: TimeInterval,
        gpuStart: TimeInterval,
        gpuEnd: TimeInterval
    ) {
        // Unions use their own lock; completion handlers can run concurrently.
        let wallBusy = searchWallUnion.record(start: wallStart, end: wallEnd)
        let gpuBusy = gpuEnd > gpuStart
            ? searchGPUUnion.record(start: gpuStart, end: gpuEnd)
            : 0
        state.lock()
        workMetrics.searchCommandsCompleted += 1
        workMetrics.searchCommandWallSeconds += wallSeconds
        workMetrics.searchCommandGPUSeconds += gpuSeconds
        workMetrics.searchCommandWallBusySeconds += wallBusy
        workMetrics.searchCommandGPUBusySeconds += gpuBusy
        state.unlock()
    }

    private func recordBuildCommand(wallSeconds: Double, gpuSeconds: Double) {
        state.lock()
        workMetrics.buildCommandsCompleted += 1
        workMetrics.buildCommandWallSeconds += wallSeconds
        workMetrics.buildCommandGPUSeconds += gpuSeconds
        state.unlock()
    }

    private func waitForBuildSubmission(
        _ submission: DatasetBuildSubmission,
        shouldContinue: (() -> Bool)?
    ) throws -> Double {
        while true {
            if let result = submission.result(until: Date(timeIntervalSinceNow: 0.05)) {
                return try result.get()
            }
            guard shouldContinue?() != false else { throw MetalSolverError.cancelled }
        }
    }

    private func enqueueBuildChunk(
        slot: DatasetSlot,
        startIndex: Int,
        count: Int,
        wallAccumulator: DatasetBuildWallAccumulator
    ) throws -> DatasetBuildSubmission {
        buildCommandSlots.wait()
        let wallStarted = ProcessInfo.processInfo.systemUptime
        enterSerializedGate(); defer { leaveSerializedGate() }
        guard let command = buildCommandQueue.makeCommandBufferWithUnretainedReferences(),
              let encoder = command.makeComputeCommandEncoder()
        else {
            buildCommandSlots.signal()
            throw MetalSolverError.commandEncoding
        }
        command.label = "buildDataset[\(startIndex)..<\(startIndex + count)]"
        encoder.label = "buildDataset"
        var height = UInt32(slot.spec.height)
        var tableSize = UInt32(slot.spec.tableSize)
        var start = UInt32(startIndex)
        encoder.setComputePipelineState(buildPipeline)
        encoder.setBuffer(slot.buffer, offset: 0, index: 0)
        encoder.setBytes(&height, length: MemoryLayout<UInt32>.size, index: 1)
        encoder.setBytes(&tableSize, length: MemoryLayout<UInt32>.size, index: 2)
        encoder.setBytes(&start, length: MemoryLayout<UInt32>.size, index: 3)
        encoder.setBuffer(constantMBuffer, offset: 0, index: 4)
        let width = min(buildPipeline.maxTotalThreadsPerThreadgroup, datasetThreadgroupSize)
        encoder.dispatchThreads(
            MTLSize(width: count, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
        encoder.endEncoding()

        let submission = DatasetBuildSubmission()
        let pipeline = buildPipeline
        let constantM = constantMBuffer
        let commandSlots = buildCommandSlots
        command.addCompletedHandler {
            [weak self, slot, submission, pipeline, constantM, commandSlots] command in
            // The command buffer uses unretained references; keep all encoded
            // resources alive until Metal has finished with this chunk.
            _ = slot
            _ = pipeline
            _ = constantM
            let wallSeconds = wallAccumulator.record(
                start: wallStarted,
                end: ProcessInfo.processInfo.systemUptime)
            let gpuSeconds = max(0, command.gpuEndTime - command.gpuStartTime)
            self?.recordBuildCommand(wallSeconds: wallSeconds, gpuSeconds: gpuSeconds)
            if let error = command.error {
                submission.resolve(.failure(
                    MetalSolverError.pipeline(error.localizedDescription)))
            } else {
                submission.resolve(.success(gpuSeconds))
            }
            commandSlots.signal()
        }
        command.commit()
        return submission
    }

    deinit {
        cancelPrefetch()
    }
}

private extension Duration {
    var seconds: Double {
        let value = components
        return Double(value.seconds) + Double(value.attoseconds) / 1e18
    }
}
