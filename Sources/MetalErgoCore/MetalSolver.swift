import Foundation
import Metal

public enum MetalSolverError: Error, LocalizedError {
    case noDevice
    case functionMissing(String)
    case pipeline(String)
    case allocation(bytes: UInt64, available: UInt64)
    case commandEncoding

    public var errorDescription: String? {
        switch self {
        case .noDevice: return "No Metal device is available"
        case .functionMissing(let name): return "Metal function '\(name)' is missing"
        case .pipeline(let message): return "Metal pipeline creation failed: \(message)"
        case .allocation(let bytes, let available):
            return "Autolykos dataset needs \(bytes) bytes plus headroom; recommended working set is \(available) bytes"
        case .commandEncoding: return "Could not create a Metal command buffer or encoder"
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

public struct DatasetBuild: Sendable {
    public let height: Int
    public let tableSize: Int
    public let bytes: UInt64
    public let seconds: Double
}

public struct SearchBatch: Sendable {
    public let baseNonce: UInt64
    public let nonceCount: Int
    public let candidates: [UInt64]
    public let gpuSeconds: Double
    public let wallSeconds: Double
}

private final class MetalBundleToken {}

public final class MetalAutolykosSolver {
    public let device: MTLDevice
    public let info: MetalDeviceInfo
    private let queue: MTLCommandQueue
    private let buildPipeline: MTLComputePipelineState
    private let searchPipeline: MTLComputePipelineState
    private var dataset: MTLBuffer?
    private var datasetHeight: Int?
    private var tableSize: Int = 0

    public init(device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws {
        guard let device else { throw MetalSolverError.noDevice }
        guard let queue = device.makeCommandQueue() else { throw MetalSolverError.noDevice }
        self.device = device
        self.queue = queue
        self.info = MetalDeviceInfo(
            name: device.name,
            registryID: device.registryID,
            recommendedWorkingSetBytes: device.recommendedMaxWorkingSetSize,
            maxBufferBytes: UInt64(device.maxBufferLength),
            unifiedMemory: device.hasUnifiedMemory
        )

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

    @discardableResult
    public func buildDataset(height: Int, tableSize override: Int? = nil) throws -> DatasetBuild {
        let n = override ?? AutolykosV2.calcN(height: height)
        let bytes = UInt64(n) * 32
        let headroom = max(UInt64(512 * 1024 * 1024), bytes / 10)
        let available = device.recommendedMaxWorkingSetSize
        guard bytes <= UInt64(device.maxBufferLength), bytes + headroom <= available else {
            throw MetalSolverError.allocation(bytes: bytes, available: available)
        }
        if datasetHeight == height, tableSize == n, dataset != nil {
            return DatasetBuild(height: height, tableSize: n, bytes: bytes, seconds: 0)
        }
        guard let buffer = device.makeBuffer(length: Int(bytes), options: .storageModePrivate),
              let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder()
        else { throw MetalSolverError.commandEncoding }

        var h = UInt32(height)
        var count = UInt32(n)
        encoder.setComputePipelineState(buildPipeline)
        encoder.setBuffer(buffer, offset: 0, index: 0)
        encoder.setBytes(&h, length: MemoryLayout<UInt32>.size, index: 1)
        encoder.setBytes(&count, length: MemoryLayout<UInt32>.size, index: 2)
        let width = min(buildPipeline.maxTotalThreadsPerThreadgroup, 256)
        encoder.dispatchThreads(MTLSize(width: n, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
        encoder.endEncoding()
        let started = ContinuousClock.now
        command.commit()
        command.waitUntilCompleted()
        if let error = command.error { throw MetalSolverError.pipeline(error.localizedDescription) }
        let elapsed = started.duration(to: .now).seconds
        dataset = buffer
        datasetHeight = height
        tableSize = n
        return DatasetBuild(height: height, tableSize: n, bytes: bytes, seconds: elapsed)
    }

    public func search(
        message: [UInt8], target: UInt256, baseNonce: UInt64, nonceCount: Int,
        threadgroupSize requested: Int? = nil
    ) throws -> SearchBatch {
        guard message.count == 32 else { throw AutolykosError.invalidMessageLength(message.count) }
        guard let dataset, let datasetHeight else { throw MetalSolverError.commandEncoding }
        let messageWords = UInt256(bigEndian: message).limbs
        var targetWords = target.limbs
        guard let messageBuffer = device.makeBuffer(bytes: messageWords, length: 32, options: .storageModeShared),
              let targetBuffer = device.makeBuffer(bytes: &targetWords, length: 32, options: .storageModeShared),
              let resultBuffer = device.makeBuffer(length: 256 * MemoryLayout<UInt64>.size, options: .storageModeShared),
              let countBuffer = device.makeBuffer(length: MemoryLayout<UInt32>.size, options: .storageModeShared),
              let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder()
        else { throw MetalSolverError.commandEncoding }
        countBuffer.contents().storeBytes(of: UInt32(0), as: UInt32.self)

        var base = baseNonce
        var height = UInt32(datasetHeight)
        var n = UInt32(tableSize)
        encoder.setComputePipelineState(searchPipeline)
        encoder.setBuffer(dataset, offset: 0, index: 0)
        encoder.setBuffer(messageBuffer, offset: 0, index: 1)
        encoder.setBuffer(targetBuffer, offset: 0, index: 2)
        encoder.setBuffer(resultBuffer, offset: 0, index: 3)
        encoder.setBuffer(countBuffer, offset: 0, index: 4)
        encoder.setBytes(&base, length: MemoryLayout<UInt64>.size, index: 5)
        encoder.setBytes(&height, length: MemoryLayout<UInt32>.size, index: 6)
        encoder.setBytes(&n, length: MemoryLayout<UInt32>.size, index: 7)
        let width = min(requested ?? 128, searchPipeline.maxTotalThreadsPerThreadgroup)
        encoder.dispatchThreads(MTLSize(width: nonceCount, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
        encoder.endEncoding()
        let started = ContinuousClock.now
        command.commit()
        command.waitUntilCompleted()
        if let error = command.error { throw MetalSolverError.pipeline(error.localizedDescription) }

        let resultCount = min(Int(countBuffer.contents().load(as: UInt32.self)), 256)
        let pointer = resultBuffer.contents().bindMemory(to: UInt64.self, capacity: 256)
        let candidates = (0..<resultCount).map { pointer[$0] }
        return SearchBatch(baseNonce: baseNonce, nonceCount: nonceCount, candidates: candidates,
            gpuSeconds: max(0, command.gpuEndTime - command.gpuStartTime),
            wallSeconds: started.duration(to: .now).seconds)
    }
}

private extension Duration {
    var seconds: Double {
        let value = components
        return Double(value.seconds) + Double(value.attoseconds) / 1e18
    }
}
