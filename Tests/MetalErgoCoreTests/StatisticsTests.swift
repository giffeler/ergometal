import XCTest
@testable import MetalErgoCore

final class StatisticsTests: XCTestCase {
    func testPrometheusIsStableAndContainsNoPoolCredentials() {
        let stats = StatisticsStore(mode: .mining)
        stats.update { snapshot in
            snapshot.poolHost = "pool.example:1234"
            snapshot.state = .searching
            snapshot.shares.accepted = 2
        }
        stats.recordBatch(nonces: 65_536, gpuSeconds: 0.1, wallSeconds: 0.2)
        let output = stats.prometheus()
        XCTAssertTrue(output.contains("ergometal_nonces_total"))
        XCTAssertTrue(output.contains("ergometal_shares_accepted_total"))
        XCTAssertFalse(output.contains("pool.example"))
    }

    func testEventWriterAppendsValidJSONLines() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let stats = StatisticsStore()
        do {
            let writer = JSONLEventWriter(path: url.path)
            writer.write(MinerEvent(sessionID: stats.snapshot().sessionID, type: "test"))
        }
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 1)
        let object = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any]
        XCTAssertEqual(object?["type"] as? String, "test")
    }
}
