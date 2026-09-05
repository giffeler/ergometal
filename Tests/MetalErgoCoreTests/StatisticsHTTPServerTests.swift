import Darwin
import Foundation
import XCTest
@testable import MetalErgoCore

final class StatisticsHTTPServerTests: XCTestCase {
    func testFragmentedRequestWaitsForCompleteHeaders() throws {
        let server = StatisticsHTTPServer(store: StatisticsStore())
        try server.start(bind: "127.0.0.1:0")
        defer { server.stop() }
        let socket = try connect(to: server)
        defer { Darwin.close(socket) }
        try send("GET /hea", to: socket)
        var descriptor = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
        XCTAssertEqual(poll(&descriptor, 1, 100), 0, "responded to an incomplete request")
        try send("lthz HTTP/1.1\r\nHost: local", to: socket)
        XCTAssertEqual(poll(&descriptor, 1, 100), 0, "responded before the final header terminator")
        try send("host\r\n\r\n", to: socket)
        XCTAssertTrue(try receive(from: socket).hasPrefix("HTTP/1.1 200 OK\r\n"))
    }

    func testOversizedHeaderIsRejected() throws {
        let server = StatisticsHTTPServer(store: StatisticsStore())
        try server.start(bind: "127.0.0.1:0")
        defer { server.stop() }
        let socket = try connect(to: server)
        defer { Darwin.close(socket) }
        try send("GET /healthz HTTP/1.1\r\nX-Large: " + String(repeating: "a", count: 8_192), to: socket)
        XCTAssertTrue(try receive(from: socket).hasPrefix("HTTP/1.1 431 "))
    }

    func testIncompleteHeaderConnectionTimesOut() throws {
        let server = StatisticsHTTPServer(store: StatisticsStore(), requestTimeout: 0.05)
        try server.start(bind: "127.0.0.1:0")
        defer { server.stop() }
        let socket = try connect(to: server)
        defer { Darwin.close(socket) }
        try send("GET /", to: socket)
        XCTAssertEqual(try receive(from: socket), "")
    }

    private func connect(to server: StatisticsHTTPServer) throws -> Int32 {
        let deadline = Date(timeIntervalSinceNow: 2)
        while server.listeningPort == nil && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        let port = try XCTUnwrap(server.listeningPort)
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw posixError() }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        var noSIGPIPE: Int32 = 1
        _ = setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &noSIGPIPE, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            let error = posixError(); Darwin.close(socket); throw error
        }
        return socket
    }

    private func send(_ text: String, to socket: Int32) throws {
        try Data(text.utf8).withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.send(socket, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                guard written > 0 else { throw posixError() }
                offset += written
            }
        }
    }

    private func receive(from socket: Int32) throws -> String {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = recv(socket, &buffer, buffer.count, 0)
            guard count >= 0 else { throw posixError() }
            if count == 0 { break }
            result.append(contentsOf: buffer.prefix(count))
            if let end = result.range(of: Data("\r\n\r\n".utf8))?.upperBound {
                let header = String(decoding: result[..<end], as: UTF8.self)
                let length = header.components(separatedBy: "\r\n")
                    .first { $0.hasPrefix("Content-Length: ") }
                    .flatMap { Int($0.dropFirst("Content-Length: ".count)) }
                if let length, result.count >= end + length { break }
            }
        }
        return String(decoding: result, as: UTF8.self)
    }

    private func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
