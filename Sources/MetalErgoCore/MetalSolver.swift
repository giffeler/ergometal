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

public struct DatasetBuild: Sendable {
    public let height: Int
    public let tableSize: Int
    public let bytes: UInt64
    public let seconds: Double
    public let activationSeconds: Double
    public let source: DatasetBuildSource
}

public struct DatasetPrefetchStatus: Sendable {
    public let height: Int
    public let completedElements: Int
    public let tableSize: Int
    public let finished: Bool
    public let seconds: Double?
    public let errorDescription: String?

    public var progress: Double {
        tableSize > 0 ? Double(completedElements) / Double(tableSize) : 0
    }
}

public struct SearchBatch: Sendable {
    public let baseNonce: UInt64
    public let nonceCount: Int
    public let candidates: [UInt64]
    public let gpuSeconds: Double
    public let wallSeconds: Double
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

private struct DatasetSpec {
    let height: Int
    let tableSize: Int
    let bytes: UInt64

    func matches(height: Int, tableSize: Int) -> Bool {
        self.height == height && self.tableSize == tableSize
    }
}

private final class DatasetSlot {
    let spec: DatasetSpec
    let buffer: MTLBuffer
    var buildSeconds: Double = 0

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
    var failure: Error?

    init(slot: DatasetSlot) {
        self.slot = slot
    }
}

public final class MetalAutolykosSolver {
    private static let maximumResults = 256
    private static let synchronousBuildChunkElements = 1_048_576
    private static let prefetchBuildChunkElements = 262_144

    public let device: MTLDevice
    public let info: MetalDeviceInfo
    private let commandQueue: MTLCommandQueue
    private let buildPipeline: MTLComputePipelineState
    private let searchPipeline: MTLComputePipelineState
    private let constantMBuffer: MTLBuffer
    private let resultBuffer: MTLBuffer
    private let resultCountBuffer: MTLBuffer
    private let searchLock = NSLock()
    private let commandGate = MetalCommandGate()
    private let state = NSCondition()
    private let prefetchWorker = DispatchQueue(label: "dev.ergometal.dataset-prefetch", qos: .userInitiated)
    private var activeDataset: DatasetSlot?
    private var prefetchTask: DatasetPrefetchTask?

    public init(device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws {
        guard let device else { throw MetalSolverError.noDevice }
        guard let commandQueue = device.makeCommandQueue(),
              let constantMBuffer = device.makeBuffer(
                length: 1_024 * MemoryLayout<UInt64>.size,
                options: .storageModeShared),
              let resultBuffer = device.makeBuffer(
                length: Self.maximumResults * MemoryLayout<UInt64>.size,
                options: .storageModeShared),
              let resultCountBuffer = device.makeBuffer(
                length: MemoryLayout<UInt32>.size,
                options: .storageModeShared)
        else { throw MetalSolverError.noDevice }
        self.device = device
        self.commandQueue = commandQueue
        self.constantMBuffer = constantMBuffer
        self.resultBuffer = resultBuffer
        self.resultCountBuffer = resultCountBuffer
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
        guard let build = library.makeFunction(name: "buildDataset") else {
            throw MetalSolverError.functionMissing("buildDataset")
        }
        guard let search = library.makeFunction(name: "searchNonces") else {
            throw MetalSolverError.functionMissing("searchNonces")
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
        descriptor.captureObject = commandQueue
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
                activationSeconds: activationStarted.duration(to: .now).seconds, source: .cached)
        }
        state.unlock()

        if let prefetched = try takePrefetchedDataset(spec: spec, shouldContinue: shouldContinue) {
            return DatasetBuild(
                height: height, tableSize: spec.tableSize, bytes: spec.bytes,
                seconds: prefetched.buildSeconds,
                activationSeconds: activationStarted.duration(to: .now).seconds,
                source: .prefetched)
        }

        state.lock()
        activeDataset = nil
        state.unlock()
        try validateWorkingSet(bytes: [spec.bytes])
        guard let buffer = device.makeBuffer(length: Int(spec.bytes), options: .storageModePrivate)
        else { throw MetalSolverError.allocation(bytes: spec.bytes, available: info.recommendedWorkingSetBytes) }
        let slot = DatasetSlot(spec: spec, buffer: buffer)
        slot.buildSeconds = try buildSynchronously(slot: slot, shouldContinue: shouldContinue)
        state.lock()
        activeDataset = slot
        state.unlock()
        return DatasetBuild(
            height: height, tableSize: spec.tableSize, bytes: spec.bytes,
            seconds: slot.buildSeconds,
            activationSeconds: activationStarted.duration(to: .now).seconds,
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
            errorDescription: task.failure?.localizedDescription)
    }

    public func cancelPrefetch() {
        state.lock()
        prefetchTask?.cancelled = true
        state.broadcast()
        state.unlock()
    }

    public func search(
        message: [UInt8], target: UInt256, baseNonce: UInt64, nonceCount: Int,
        threadgroupSize requested: Int? = nil
    ) throws -> SearchBatch {
        searchLock.lock(); defer { searchLock.unlock() }
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
        commandGate.enter(); defer { commandGate.leave() }
        guard let command = commandQueue.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder()
        else { throw MetalSolverError.commandEncoding }
        command.label = "searchNonces"
        encoder.label = "searchNonces"
        resultCountBuffer.contents().storeBytes(of: UInt32(0), as: UInt32.self)

        var base = baseNonce
        var n = UInt32(dataset.spec.tableSize)
        encoder.setComputePipelineState(searchPipeline)
        encoder.setBuffer(dataset.buffer, offset: 0, index: 0)
        messageWords.withUnsafeBytes {
            encoder.setBytes($0.baseAddress!, length: $0.count, index: 1)
        }
        targetWords.withUnsafeBytes {
            encoder.setBytes($0.baseAddress!, length: $0.count, index: 2)
        }
        encoder.setBuffer(resultBuffer, offset: 0, index: 3)
        encoder.setBuffer(resultCountBuffer, offset: 0, index: 4)
        encoder.setBytes(&base, length: MemoryLayout<UInt64>.size, index: 5)
        encoder.setBytes(&n, length: MemoryLayout<UInt32>.size, index: 6)
        let width = min(requested ?? 128, searchPipeline.maxTotalThreadsPerThreadgroup)
        encoder.dispatchThreads(MTLSize(width: nonceCount, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
        encoder.endEncoding()
        let started = ContinuousClock.now
        command.commit()
        command.waitUntilCompleted()
        if let error = command.error { throw MetalSolverError.pipeline(error.localizedDescription) }

        let rawResultCount = resultCountBuffer.contents().load(as: UInt32.self)
        guard rawResultCount <= Self.maximumResults else {
            throw MetalSolverError.resultOverflow(limit: Self.maximumResults, found: rawResultCount)
        }
        let resultCount = Int(rawResultCount)
        let pointer = resultBuffer.contents().bindMemory(to: UInt64.self, capacity: Self.maximumResults)
        let candidates = (0..<resultCount).map { pointer[$0] }.sorted()
        return SearchBatch(baseNonce: baseNonce, nonceCount: nonceCount, candidates: candidates,
            gpuSeconds: max(0, command.gpuEndTime - command.gpuStartTime),
            wallSeconds: started.duration(to: .now).seconds)
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
        return DatasetSpec(height: height, tableSize: tableSize, bytes: bytes)
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
    ) throws -> DatasetSlot? {
        state.lock()
        guard let task = prefetchTask else {
            state.unlock()
            return nil
        }
        guard task.slot.spec.matches(height: spec.height, tableSize: spec.tableSize) else {
            task.cancelled = true
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
        return task.slot
    }

    private func buildSynchronously(
        slot: DatasetSlot,
        shouldContinue: (() -> Bool)?
    ) throws -> Double {
        let started = ContinuousClock.now
        var startIndex = 0
        while startIndex < slot.spec.tableSize {
            guard shouldContinue?() != false else { throw MetalSolverError.cancelled }
            let count = min(Self.synchronousBuildChunkElements, slot.spec.tableSize - startIndex)
            try encodeBuildChunk(slot: slot, startIndex: startIndex, count: count)
            startIndex += count
        }
        return started.duration(to: .now).seconds
    }

    private func runPrefetch(_ task: DatasetPrefetchTask) {
        do {
            while task.completedElements < task.slot.spec.tableSize {
                state.lock()
                let cancelled = task.cancelled
                state.unlock()
                guard !cancelled else { throw MetalSolverError.cancelled }
                let count = min(
                    Self.prefetchBuildChunkElements,
                    task.slot.spec.tableSize - task.completedElements)
                try encodeBuildChunk(
                    slot: task.slot,
                    startIndex: task.completedElements,
                    count: count)
                state.lock()
                task.completedElements += count
                state.broadcast()
                state.unlock()
            }
            task.slot.buildSeconds = task.started.duration(to: .now).seconds
        } catch {
            state.lock()
            task.failure = error
            state.unlock()
        }
        state.lock()
        task.finished = true
        state.broadcast()
        state.unlock()
    }

    private func encodeBuildChunk(slot: DatasetSlot, startIndex: Int, count: Int) throws {
        commandGate.enter(); defer { commandGate.leave() }
        guard let command = commandQueue.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder()
        else { throw MetalSolverError.commandEncoding }
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
        let width = min(buildPipeline.maxTotalThreadsPerThreadgroup, 256)
        encoder.dispatchThreads(
            MTLSize(width: count, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        if let error = command.error {
            throw MetalSolverError.pipeline(error.localizedDescription)
        }
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
