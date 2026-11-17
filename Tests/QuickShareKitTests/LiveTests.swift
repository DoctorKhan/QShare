import Foundation
import Network
import XCTest
@testable import QuickShareKit

/// Sends a request to an already-running app. Skipped unless QSHARE_LIVE_PORT is set.
final class LiveTests: XCTestCase {
    func testLiveRequestThenWalkAway() async throws {
        guard let value = ProcessInfo.processInfo.environment["QSHARE_LIVE_PORT"],
              let raw = UInt16(value), let port = NWEndpoint.Port(rawValue: raw)
        else { throw XCTSkip("Set QSHARE_LIVE_PORT to run against a running app") }
        let sender = TestSender(port: port)
        try await sender.handshake(name: "Panel Test")
        try sender.sendSharing { frame in
            frame.type = .introduction
            var meta = Sharing_Nearby_FileMetadata()
            meta.name = "panel-check.txt"
            meta.payloadID = 1
            meta.size = 10
            frame.introduction.fileMetadata = [meta]
        }
        try await Task.sleep(nanoseconds: 8_000_000_000)
        sender.drop()
    }
}
