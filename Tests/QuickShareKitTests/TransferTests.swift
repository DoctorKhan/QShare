import Foundation
import XCTest
@testable import QuickShareKit

final class TransferTests: XCTestCase {
    private var host: TestHost!

    override func tearDown() {
        host?.stop()
        host = nil
    }

    private func introduce(_ sender: TestSender, files: [(id: Int64, name: String, data: Data, hash: Int64)]) throws {
        try sender.sendSharing { frame in
            frame.type = .introduction
            frame.introduction.fileMetadata = files.map { file in
                var meta = Sharing_Nearby_FileMetadata()
                meta.name = file.name
                meta.payloadID = file.id
                meta.size = Int64(file.data.count)
                meta.mimeType = "application/octet-stream"
                if file.hash != 0 { meta.attachmentHash = file.hash }
                return meta
            }
        }
    }

    func testReceivesMultipleFiles() async throws {
        host = try TestHost()
        let port = try await host.start()
        let big = Data.random(count: 3 * 1024 * 1024 + 123)
        let small = Data("hello from the phone".utf8)

        let sender = TestSender(port: port)
        try await sender.handshake(name: "Galaxy S24")
        try introduce(sender, files: [(1, "photo.jpg", big, 0), (2, "../../evil/note.txt", small, 0)])
        let response = try await sender.nextSharing()
        XCTAssertEqual(response?.type, .response)
        XCTAssertEqual(response?.connectionResponse.status, .accept)

        try sender.sendFile(id: 1, data: big, range: 0..<big.count, finish: true)
        try sender.sendFile(id: 2, data: small, range: 0..<small.count, finish: true)
        try await sender.waitForClose()

        let host = host!
        await waitUntil("completion") { host.transfers.first?.state == .completed }
        let transfer = try XCTUnwrap(host.transfers.first)
        XCTAssertEqual(transfer.deviceName, "Galaxy S24")
        XCTAssertEqual(transfer.deviceType, .phone)
        XCTAssertEqual(transfer.pin, sender.pin)
        XCTAssertEqual(transfer.pin.count, 4)
        XCTAssertEqual(host.visibleFiles(), ["note.txt", "photo.jpg"])
        XCTAssertEqual(try Data(contentsOf: host.destination.appendingPathComponent("photo.jpg")), big)
        XCTAssertEqual(try Data(contentsOf: host.destination.appendingPathComponent("note.txt")), small)
        XCTAssertEqual(transfer.savedFiles.count, 2)
        XCTAssertTrue(host.partialFiles().isEmpty)
    }

    func testDoesNotOverwriteExistingFile() async throws {
        host = try TestHost()
        let port = try await host.start()
        try Data("original".utf8).write(to: host.destination.appendingPathComponent("doc.pdf"))
        let data = Data.random(count: 5000)

        let sender = TestSender(port: port)
        try await sender.handshake()
        try introduce(sender, files: [(7, "doc.pdf", data, 0)])
        _ = try await sender.nextSharing()
        try sender.sendFile(id: 7, data: data, range: 0..<data.count, finish: true)
        try await sender.waitForClose()

        let host = host!
        await waitUntil("completion") { host.transfers.first?.state == .completed }
        XCTAssertEqual(host.visibleFiles(), ["doc (1).pdf", "doc.pdf"])
        XCTAssertEqual(try Data(contentsOf: host.destination.appendingPathComponent("doc.pdf")), Data("original".utf8))
        XCTAssertEqual(try Data(contentsOf: host.destination.appendingPathComponent("doc (1).pdf")), data)
    }

    func testReceivesText() async throws {
        host = try TestHost()
        let port = try await host.start()
        let sender = TestSender(port: port)
        try await sender.handshake()
        try sender.sendSharing { frame in
            frame.type = .introduction
            var meta = Sharing_Nearby_TextMetadata()
            meta.type = .url
            meta.payloadID = 42
            meta.textTitle = "example.com"
            frame.introduction.textMetadata = [meta]
        }
        let response = try await sender.nextSharing()
        XCTAssertEqual(response?.connectionResponse.status, .accept)
        try sender.sendBytes(id: 42, data: Data("https://example.com/page".utf8))
        try await sender.waitForClose()

        let host = host!
        await waitUntil("completion") { host.transfers.first?.state == .completed }
        XCTAssertEqual(host.transfers.first?.text, "https://example.com/page")
        XCTAssertEqual(host.transfers.first?.textKind, .url)
    }

    func testDecline() async throws {
        host = try TestHost()
        host.autoAccept = false
        let port = try await host.start()
        let sender = TestSender(port: port)
        try await sender.handshake()
        try introduce(sender, files: [(1, "a.bin", Data.random(count: 10), 0)])

        let host = host!
        await waitUntil("request") { host.transfers.count == 1 }
        XCTAssertEqual(host.transfers[0].state, .awaitingApproval)
        host.transfers[0].decline()
        let response = try await sender.nextSharing()
        XCTAssertEqual(response?.connectionResponse.status, .reject)
        await waitUntil("declined") { host.transfers[0].state == .declined }
        XCTAssertTrue(host.visibleFiles().isEmpty)
    }

    func testInterruptedTransferResumes() async throws {
        host = try TestHost()
        let port = try await host.start()
        let data = Data.random(count: 2 * 1024 * 1024)
        let half = 1024 * 1024
        let host = host!

        // First attempt dies halfway through.
        let first = TestSender(port: port)
        try await first.handshake()
        try introduce(first, files: [(1, "video.mp4", data, 9001)])
        let firstResponse = try await first.nextSharing()
        XCTAssertTrue(firstResponse?.connectionResponse.attachmentDetails.isEmpty ?? false)
        try first.sendFile(id: 1, data: data, range: 0..<half, finish: false)
        await waitUntil("first half") { host.transfers.first?.bytesReceived == Int64(half) }
        first.drop()
        await waitUntil("failure") {
            if case .failed = host.transfers.first?.state { return true }
            return false
        }
        XCTAssertTrue(host.visibleFiles().isEmpty)
        XCTAssertEqual(host.partialFiles().count, 1)

        // Second attempt: the receiver says how much it has, the sender continues from there.
        let second = TestSender(port: port)
        try await second.handshake()
        try introduce(second, files: [(55, "video.mp4", data, 9001)])
        let response = try await second.nextSharing()
        XCTAssertEqual(response?.connectionResponse.status, .accept)
        let offered = response?.connectionResponse.attachmentDetails[9001]?
            .fileAttachmentDetails.receiverExistingFileSize
        XCTAssertEqual(offered, Int64(half))
        try second.sendFile(id: 55, data: data, range: half..<data.count, finish: true)
        try await second.waitForClose()

        await waitUntil("completion") { host.transfers.count == 2 && host.transfers[1].state == .completed }
        XCTAssertEqual(host.transfers[1].resumedBytes, Int64(half))
        XCTAssertEqual(try Data(contentsOf: host.destination.appendingPathComponent("video.mp4")), data)
        XCTAssertTrue(host.partialFiles().isEmpty)
    }

    func testSenderThatIgnoresResumeOfferStillWorks() async throws {
        host = try TestHost()
        let port = try await host.start()
        let data = Data.random(count: 600_000)
        let host = host!

        let first = TestSender(port: port)
        try await first.handshake()
        try introduce(first, files: [(1, "clip.mov", data, 77)])
        _ = try await first.nextSharing()
        try first.sendFile(id: 1, data: data, range: 0..<200_000, finish: false)
        await waitUntil("partial data") { host.transfers.first?.bytesReceived == 200_000 }
        first.drop()
        await waitUntil("failure") { host.transfers.first?.state.isFinished == true }

        // The sender is offered a resume point but starts from the beginning anyway.
        let second = TestSender(port: port)
        try await second.handshake()
        try introduce(second, files: [(2, "clip.mov", data, 77)])
        let response = try await second.nextSharing()
        XCTAssertEqual(response?.connectionResponse.attachmentDetails[77]?
            .fileAttachmentDetails.receiverExistingFileSize, 200_000)
        try second.sendFile(id: 2, data: data, range: 0..<data.count, finish: true)
        try await second.waitForClose()

        await waitUntil("completion") { host.transfers.count == 2 && host.transfers[1].state == .completed }
        XCTAssertEqual(host.transfers[1].resumedBytes, 0)
        XCTAssertEqual(try Data(contentsOf: host.destination.appendingPathComponent("clip.mov")), data)
    }

    func testCompletedFilesSurviveAFailedBatch() async throws {
        host = try TestHost()
        let port = try await host.start()
        let one = Data.random(count: 100_000)
        let two = Data.random(count: 300_000)
        let host = host!

        let sender = TestSender(port: port)
        try await sender.handshake()
        try introduce(sender, files: [(1, "one.jpg", one, 0), (2, "two.jpg", two, 0)])
        _ = try await sender.nextSharing()
        try sender.sendFile(id: 1, data: one, range: 0..<one.count, finish: true)
        try sender.sendFile(id: 2, data: two, range: 0..<100_000, finish: false)
        await waitUntil("data") { host.transfers.first?.bytesReceived == 200_000 }
        sender.drop()

        await waitUntil("failure") { host.transfers.first?.state.isFinished == true }
        XCTAssertEqual(host.visibleFiles(), ["one.jpg"])
        XCTAssertEqual(host.transfers.first?.savedFiles.count, 1)
        // No stable identifier was supplied, so the half file can't be continued and is removed.
        XCTAssertTrue(host.partialFiles().isEmpty)
    }

    func testSenderCancel() async throws {
        host = try TestHost()
        let port = try await host.start()
        let data = Data.random(count: 400_000)
        let host = host!

        let sender = TestSender(port: port)
        try await sender.handshake()
        try introduce(sender, files: [(1, "big.zip", data, 5)])
        _ = try await sender.nextSharing()
        try sender.sendFile(id: 1, data: data, range: 0..<100_000, finish: false)
        try sender.sendSharing { $0.type = .cancel }

        await waitUntil("cancel") { host.transfers.first?.state == .cancelled(bySender: true) }
        XCTAssertTrue(host.visibleFiles().isEmpty)
        XCTAssertTrue(host.partialFiles().isEmpty)
    }

    func testTamperedMessageIsRejected() throws {
        let key = { CryptoKitKey.make() }
        let keys = SessionKeys(decryptKey: key(), receiveHMACKey: key(), encryptKey: key(), sendHMACKey: key(), pin: "0000")
        let mirrored = SessionKeys(decryptKey: keys.encryptKey, receiveHMACKey: keys.sendHMACKey,
                                   encryptKey: keys.decryptKey, sendHMACKey: keys.receiveHMACKey, pin: "0000")
        let a = SecureChannel(keys: keys)
        let b = SecureChannel(keys: mirrored)
        let sealed = try a.seal(Data("payload".utf8))
        XCTAssertEqual(try b.open(sealed), Data("payload".utf8))
        // Replaying the same message must fail the sequence check.
        XCTAssertThrowsError(try b.open(sealed))
        var tampered = try a.seal(Data("payload".utf8))
        tampered[tampered.count / 2] ^= 0xFF
        XCTAssertThrowsError(try b.open(tampered))
    }

    func testNameSanitizing() {
        XCTAssertEqual(FileStore.sanitize("../../etc/passwd"), "passwd")
        XCTAssertEqual(FileStore.sanitize("..\\..\\boot.ini"), "boot.ini")
        XCTAssertEqual(FileStore.sanitize(".hidden"), "hidden")
        XCTAssertEqual(FileStore.sanitize(".."), "Received File")
        XCTAssertEqual(FileStore.sanitize("a:b.txt"), "a_b.txt")
        XCTAssertLessThanOrEqual(FileStore.sanitize(String(repeating: "x", count: 600) + ".jpg").utf8.count, 255)
    }

    func testEndpointInfoRoundTrip() {
        let info = EndpointInfo(deviceType: .laptop, name: "Khan’s MacBook")
        let parsed = EndpointInfo(data: info.serialized())
        XCTAssertEqual(parsed?.name, "Khan’s MacBook")
        XCTAssertEqual(parsed?.deviceType, .laptop)
        XCTAssertEqual(EndpointID.serviceName(for: "AbC1").count, 14)
    }
}

import CryptoKit

enum CryptoKitKey {
    static func make() -> SymmetricKey { SymmetricKey(size: .bits256) }
}

extension TransferTests {
    func testSmallFileSentAsBytesPayload() async throws {
        let host = try TestHost()
        defer { host.stop() }
        let port = try await host.start()
        let data = Data("tiny file body".utf8)

        let sender = TestSender(port: port)
        try await sender.handshake()
        try sender.sendSharing { frame in
            frame.type = .introduction
            var meta = Sharing_Nearby_FileMetadata()
            meta.name = "tiny.txt"
            meta.payloadID = 314
            meta.size = Int64(data.count)
            frame.introduction.fileMetadata = [meta]
        }
        _ = try await sender.nextSharing()
        try sender.sendBytes(id: 314, data: data)
        try await sender.waitForClose()

        await waitUntil("completion") { host.transfers.first?.state == .completed }
        XCTAssertEqual(try Data(contentsOf: host.destination.appendingPathComponent("tiny.txt")), data)
    }
}
