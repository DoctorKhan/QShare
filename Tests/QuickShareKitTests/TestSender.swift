import CryptoKit
import Foundation
import Network
import XCTest
@testable import QuickShareKit

struct TestTimeout: Error {}

/// Plays the phone's side of the protocol against an `InboundConnection`.
final class TestSender {
    private let framed: FramedConnection
    private let queue = DispatchQueue(label: "test.sender")
    private var iterator: AsyncStream<Data>.AsyncIterator
    private var channel: SecureChannel!
    private var pendingBytes: [Int64: Data] = [:]
    private(set) var pin = ""

    init(port: NWEndpoint.Port) {
        let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        framed = FramedConnection(connection: connection)
        var continuation: AsyncStream<Data>.Continuation!
        let stream = AsyncStream<Data> { continuation = $0 }
        iterator = stream.makeAsyncIterator()
        let sink = continuation!
        framed.onFrame = { sink.yield($0) }
        framed.onClose = { _ in sink.finish() }
        framed.start(queue: queue)
    }

    /// Next raw frame, or nil if the connection closed.
    func next() async -> Data? {
        await iterator.next()
    }

    func handshake(name: String = "Test Galaxy") async throws {
        var request = OfflineFrame()
        request.version = .v1
        request.v1.type = .connectionRequest
        request.v1.connectionRequest.endpointID = "TEST"
        request.v1.connectionRequest.endpointName = name
        request.v1.connectionRequest.endpointInfo = EndpointInfo(deviceType: .phone, name: name).serialized()
        framed.send(try request.serializedData())

        let key = P256.KeyAgreement.PrivateKey()
        var finished = Securegcm_Ukey2ClientFinished()
        finished.publicKey = try Ukey2.serializedPublicKey(key.publicKey)
        var finishMessage = Securegcm_Ukey2Message()
        finishMessage.messageType = .clientFinish
        finishMessage.messageData = try finished.serializedData()
        let finishData = try finishMessage.serializedData()

        var commitment = Securegcm_Ukey2ClientInit.CipherCommitment()
        commitment.handshakeCipher = .p256Sha512
        commitment.commitment = Data(SHA512.hash(data: finishData))
        var clientInit = Securegcm_Ukey2ClientInit()
        clientInit.version = 1
        clientInit.random = Data.random(count: 32)
        clientInit.cipherCommitments = [commitment]
        clientInit.nextProtocol = Ukey2.nextProtocol
        var initMessage = Securegcm_Ukey2Message()
        initMessage.messageType = .clientInit
        initMessage.messageData = try clientInit.serializedData()
        let initData = try initMessage.serializedData()
        framed.send(initData)

        guard let serverInitData = await next() else { throw TestTimeout() }
        let serverMessage = try Securegcm_Ukey2Message(serializedBytes: serverInitData)
        XCTAssertEqual(serverMessage.messageType, .serverInit)
        let serverInit = try Securegcm_Ukey2ServerInit(serializedBytes: serverMessage.messageData)
        let serverKey = try Ukey2.parsePublicKey(serverInit.publicKey)
        framed.send(finishData)

        let keys = try Ukey2.deriveKeys(
            privateKey: key, peerKey: serverKey,
            clientInitMessage: initData, serverInitMessage: serverInitData, role: .client)
        channel = SecureChannel(keys: keys)
        pin = keys.pin

        var response = OfflineFrame()
        response.version = .v1
        response.v1.type = .connectionResponse
        response.v1.connectionResponse.response = .accept
        framed.send(try response.serializedData())

        guard let serverResponseData = await next() else { throw TestTimeout() }
        let serverResponse = try OfflineFrame(serializedBytes: serverResponseData)
        XCTAssertEqual(serverResponse.v1.type, .connectionResponse)
        XCTAssertEqual(serverResponse.v1.connectionResponse.response, .accept)

        // Paired key exchange, as Android does it.
        try sendSharing { $0.type = .pairedKeyEncryption }
        let pairedKey = try await nextSharing()
        XCTAssertEqual(pairedKey?.type, .pairedKeyEncryption)
        try sendSharing {
            $0.type = .pairedKeyResult
            $0.pairedKeyResult.status = .unable
        }
        let pairedResult = try await nextSharing()
        XCTAssertEqual(pairedResult?.type, .pairedKeyResult)
    }

    /// Next decrypted offline frame, or nil when the connection closed.
    func nextOffline() async throws -> OfflineFrame? {
        guard let data = await next() else { return nil }
        return try OfflineFrame(serializedBytes: try channel.open(data))
    }

    /// Next sharing-layer frame, skipping keep-alives. Nil when the connection closed
    /// or the receiver sent a disconnection.
    func nextSharing() async throws -> Sharing_Nearby_V1Frame? {
        while let frame = try await nextOffline() {
            switch frame.v1.type {
            case .disconnection:
                return nil
            case .payloadTransfer:
                let payload = frame.v1.payloadTransfer
                guard payload.payloadHeader.type == .bytes else { continue }
                var buffer = pendingBytes[payload.payloadHeader.id] ?? Data()
                buffer.append(payload.payloadChunk.body)
                if payload.payloadChunk.flags & 1 != 0 {
                    pendingBytes[payload.payloadHeader.id] = nil
                    return try SharingFrame(serializedBytes: buffer).v1
                }
                pendingBytes[payload.payloadHeader.id] = buffer
            default:
                continue
            }
        }
        return nil
    }

    /// Waits until the receiver disconnects or the socket closes.
    func waitForClose() async throws {
        while let frame = try await nextOffline() {
            if frame.v1.type == .disconnection { return }
        }
    }

    func sendOffline(_ frame: OfflineFrame) throws {
        framed.send(try channel.seal(try frame.serializedData()))
    }

    func sendSharing(_ build: (inout Sharing_Nearby_V1Frame) -> Void) throws {
        var sharing = SharingFrame()
        sharing.version = .v1
        build(&sharing.v1)
        try sendBytes(id: Int64.random(in: 1...Int64.max), data: try sharing.serializedData())
    }

    func sendBytes(id: Int64, data: Data) throws {
        try sendChunk(id: id, type: .bytes, total: Int64(data.count), offset: 0, body: data, last: false)
        try sendChunk(id: id, type: .bytes, total: Int64(data.count), offset: Int64(data.count), body: Data(), last: true)
    }

    /// Sends `data[range]` of a file payload in chunks, optionally followed by the final empty chunk.
    func sendFile(id: Int64, data: Data, range: Range<Int>, finish: Bool, chunkSize: Int = 64 * 1024) throws {
        var offset = range.lowerBound
        while offset < range.upperBound {
            let end = min(offset + chunkSize, range.upperBound)
            try sendChunk(id: id, type: .file, total: Int64(data.count), offset: Int64(offset),
                          body: data.subdata(in: offset..<end), last: false)
            offset = end
        }
        if finish {
            try sendChunk(id: id, type: .file, total: Int64(data.count), offset: Int64(data.count),
                          body: Data(), last: true)
        }
    }

    private func sendChunk(
        id: Int64, type: Location_Nearby_Connections_PayloadTransferFrame.PayloadHeader.PayloadType,
        total: Int64, offset: Int64, body: Data, last: Bool
    ) throws {
        var frame = OfflineFrame()
        frame.version = .v1
        frame.v1.type = .payloadTransfer
        frame.v1.payloadTransfer.packetType = .data
        frame.v1.payloadTransfer.payloadHeader.id = id
        frame.v1.payloadTransfer.payloadHeader.type = type
        frame.v1.payloadTransfer.payloadHeader.totalSize = total
        frame.v1.payloadTransfer.payloadChunk.offset = offset
        frame.v1.payloadTransfer.payloadChunk.flags = last ? 1 : 0
        frame.v1.payloadTransfer.payloadChunk.body = body
        try sendOffline(frame)
    }

    /// Kills the TCP connection without any goodbye, like a phone walking out of range.
    func drop() {
        framed.close()
    }
}

/// A bare TCP listener on localhost that hands connections to `InboundConnection`.
final class TestHost {
    let destination: URL
    let listener: NWListener
    var autoAccept = true
    private let queue = DispatchQueue(label: "test.host")
    private var connections: [InboundConnection] = []
    private let lock = NSLock()
    private var _transfers: [IncomingTransfer] = []

    var transfers: [IncomingTransfer] {
        lock.lock()
        defer { lock.unlock() }
        return _transfers
    }

    init(resumeEnabled: Bool = true) throws {
        destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("qshare-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        listener = try NWListener(using: .tcp, on: .any)
        let environment = InboundConnection.Environment(destination: destination, resumeEnabled: resumeEnabled)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            let inbound = InboundConnection(connection: connection, environment: environment)
            inbound.onTransfer = { [weak self] transfer in
                guard let self else { return }
                self.lock.lock()
                self._transfers.append(transfer)
                self.lock.unlock()
                if self.autoAccept { transfer.accept() }
            }
            self.connections.append(inbound)
            inbound.start()
        }
    }

    func start() async throws -> NWEndpoint.Port {
        listener.start(queue: queue)
        for _ in 0..<200 {
            if let port = listener.port, port.rawValue != 0 { return port }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw TestTimeout()
    }

    func stop() {
        listener.cancel()
        try? FileManager.default.removeItem(at: destination)
    }

    /// Files in the destination, ignoring the hidden in-flight folder.
    func visibleFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? [])
            .filter { !$0.hasPrefix(".") }.sorted()
    }

    func partialFiles() -> [URL] {
        let folder = destination.appendingPathComponent(FileStore.partialFolderName)
        return (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    }
}

func waitUntil(timeout: TimeInterval = 10, _ what: String = "condition",
               file: StaticString = #filePath, line: UInt = #line,
               _ condition: @escaping () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTFail("Timed out waiting for \(what)", file: file, line: line)
}
