import Foundation
import Network
import XCTest
@testable import QuickShareKit

/// Exercises the real listener (including its Bonjour registration) end to end.
final class ReceiverTests: XCTestCase {
    func testReceiverAcceptsATransferAndSurvivesRestart() async throws {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("qshare-receiver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destination) }

        let receiver = QuickShareReceiver(configuration: .init(deviceName: "Test Mac", destination: destination))
        receiver.onRequest = { $0.accept() }
        var finished: [TransferState] = []
        receiver.onFinished = { finished.append($0.state) }
        receiver.start()
        defer { receiver.stop() }

        func port() -> UInt16? {
            if case .ready(let port) = receiver.status, port != 0 { return port }
            return nil
        }
        func send(_ name: String, _ data: Data) async throws {
            let sender = TestSender(port: NWEndpoint.Port(rawValue: port()!)!)
            try await sender.handshake()
            try sender.sendSharing { frame in
                frame.type = .introduction
                var meta = Sharing_Nearby_FileMetadata()
                meta.name = name
                meta.payloadID = 1
                meta.size = Int64(data.count)
                frame.introduction.fileMetadata = [meta]
            }
            let response = try await sender.nextSharing()
            XCTAssertEqual(response?.connectionResponse.status, .accept)
            try sender.sendFile(id: 1, data: data, range: 0..<data.count, finish: true)
            try await sender.waitForClose()
        }

        await waitUntil("listener ready") { port() != nil }
        let first = Data.random(count: 250_000)
        try await send("first.bin", first)
        await waitUntil("first transfer") { finished == [.completed] }
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("first.bin")), first)

        // Simulate what happens after a network change or wake: the listener is rebuilt.
        let oldPort = port()
        receiver.restart()
        await waitUntil("listener ready again") { port() != nil && port() != oldPort }
        let second = Data.random(count: 1000)
        try await send("second.bin", second)
        await waitUntil("second transfer") { finished == [.completed, .completed] }
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("second.bin")), second)
        XCTAssertEqual(receiver.transfers.count, 2)
    }

    func testStaysDiscoverableAfterReannouncing() async throws {
        let destination = FileManager.default.temporaryDirectory
        let receiver = QuickShareReceiver(configuration: .init(
            deviceName: "Test Mac", destination: destination, endpointID: "Zq9x"))
        receiver.start()
        defer { receiver.stop() }
        await waitUntil("listener ready") {
            if case .ready = receiver.status { return true }
            return false
        }
        receiver.announceNow()
        try await Task.sleep(nanoseconds: 1_500_000_000)

        let expected = EndpointID.serviceName(for: "Zq9x")
        let found = Found()
        let browser = NWBrowser(for: .bonjour(type: QuickShareReceiver.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { results, _ in
            for result in results {
                if case .service(let name, _, _, _) = result.endpoint, name == expected { found.set() }
            }
        }
        browser.start(queue: .global())
        defer { browser.cancel() }
        await waitUntil("service visible after re-announce") { found.value }
    }
}

extension ReceiverTests {
    func testKeepsTheSamePortAcrossRestarts() async throws {
        let probe = QuickShareReceiver(configuration: .init(deviceName: "Probe", destination: FileManager.default.temporaryDirectory))
        probe.start()
        var chosen: UInt16 = 0
        await waitUntil("probe ready") {
            if case .ready(let port) = probe.status { chosen = port; return port != 0 }
            return false
        }
        probe.stop()
        try await Task.sleep(nanoseconds: 300_000_000)

        let receiver = QuickShareReceiver(configuration: .init(
            deviceName: "Fixed", destination: FileManager.default.temporaryDirectory, preferredPort: chosen))
        receiver.start()
        defer { receiver.stop() }
        await waitUntil("ready on preferred port") { receiver.status == .ready(port: chosen) }
        receiver.restart()
        try await Task.sleep(nanoseconds: 300_000_000)
        await waitUntil("ready on the same port after restart") { receiver.status == .ready(port: chosen) }
    }
}

private final class Found: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set() { lock.lock(); flag = true; lock.unlock() }
}
