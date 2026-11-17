import CryptoKit
import Foundation
import Network
import os

typealias OfflineFrame = Location_Nearby_Connections_OfflineFrame
typealias SharingFrame = Sharing_Nearby_Frame

/// One connection from a sending device, from TCP accept through to the last file.
/// Everything here runs on the connection's own serial queue; UI-facing state is
/// published on the main queue.
final class InboundConnection {
    struct Environment {
        var destination: URL
        var resumeEnabled: Bool
    }

    private enum Phase {
        case awaitingConnectionRequest, awaitingClientInit, awaitingClientFinish
        case awaitingConnectionResponse, established, closed
    }

    private final class FileSlot {
        let file: IncomingFile
        let partialURL: URL
        /// Bytes of an earlier attempt we told the sender we already have.
        let offered: Int64
        var handle: FileHandle?
        var written: Int64 = 0
        var started = false
        var done = false

        init(file: IncomingFile, partialURL: URL, offered: Int64) {
            self.file = file
            self.partialURL = partialURL
            self.offered = offered
        }
    }

    static let keepAliveInterval: TimeInterval = 10
    static let stallTimeout: TimeInterval = 30
    static let handshakeTimeout: TimeInterval = 60
    static let maxBytesPayload = 8 * 1024 * 1024

    /// Called on the main queue when the sender has described what it wants to send.
    var onTransfer: ((IncomingTransfer) -> Void)?
    /// Called on the main queue after the transfer's state changed.
    var onTransferChanged: ((IncomingTransfer) -> Void)?
    /// Called on the connection queue once the connection is gone.
    var onClosed: (() -> Void)?

    private let log = Logger(subsystem: "app.qshare.mac", category: "connection")
    private let tag = String(UUID().uuidString.prefix(4))
    private let queue: DispatchQueue
    private let framed: FramedConnection
    private let environment: Environment
    private let store: FileStore
    private let openedAt = Date()

    private var phase = Phase.awaitingConnectionRequest
    private var remoteName = "Unknown device"
    private var remoteType = DeviceType.unknown

    // Handshake
    private var clientInitMessage = Data()
    private var serverInitMessage = Data()
    private var commitment = Data()
    private var privateKey: P256.KeyAgreement.PrivateKey?
    private var channel: SecureChannel?

    // Transfer
    private var bytesPayloads: [Int64: Data] = [:]
    private var transfer: IncomingTransfer?
    private var slots: [Int64: FileSlot] = [:]
    private var textPayloadID: Int64?
    private var textReceived = false
    private var accepted = false
    private var finished = false

    // Liveness and progress
    private var timer: DispatchSourceTimer?
    private var lastReceived = Date()
    private var lastKeepAliveSent = Date()
    private var receivedBytes: Int64 = 0
    private var resumedBytes: Int64 = 0
    private var lastProgressAt = Date()
    private var lastProgressBytes: Int64 = 0
    private var speed: Double = 0

    init(connection: NWConnection, environment: Environment) {
        self.queue = DispatchQueue(label: "qshare.connection")
        self.framed = FramedConnection(connection: connection)
        self.environment = environment
        self.store = FileStore(destination: environment.destination)
    }

    func start() {
        framed.onFrame = { [weak self] data in self?.receive(data) }
        framed.onClose = { [weak self] error in self?.connectionClosed(error) }
        framed.start(queue: queue)
        log.notice("[\(self.tag, privacy: .public)] connection opened from \(String(describing: self.framed.connection.endpoint), privacy: .public)")

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    /// Drops the connection (used when the app shuts the receiver down).
    func abort() {
        queue.async { self.fail("Receiving was stopped") }
    }

    // MARK: - Incoming frames

    private func receive(_ data: Data) {
        lastReceived = Date()
        do {
            switch phase {
            case .awaitingConnectionRequest: try handleConnectionRequest(data)
            case .awaitingClientInit: try handleClientInit(data)
            case .awaitingClientFinish: try handleClientFinish(data)
            case .awaitingConnectionResponse: try handleConnectionResponse(data)
            case .established: try handleEncrypted(data)
            case .closed: break
            }
        } catch {
            log.error("[\(self.tag, privacy: .public)] error in phase \(String(describing: self.phase), privacy: .public): \(String(describing: error), privacy: .public)")
            fail(error.localizedDescription)
        }
    }

    private func handleConnectionRequest(_ data: Data) throws {
        let frame = try OfflineFrame(serializedBytes: data)
        guard frame.v1.type == .connectionRequest else {
            throw QSError.protocolViolation("Expected a connection request")
        }
        let request = frame.v1.connectionRequest
        if let info = EndpointInfo(data: request.endpointInfo) {
            remoteType = info.deviceType
            if let name = info.name, !name.isEmpty { remoteName = name }
        }
        if remoteName == "Unknown device", !request.endpointName.isEmpty {
            remoteName = request.endpointName
        }
        log.notice("[\(self.tag, privacy: .public)] connection request from '\(self.remoteName, privacy: .public)'")
        phase = .awaitingClientInit
    }

    private func handleClientInit(_ data: Data) throws {
        let message = try Securegcm_Ukey2Message(serializedBytes: data)
        guard message.messageType == .clientInit else {
            throw QSError.protocolViolation("Expected a key exchange request")
        }
        let clientInit = try Securegcm_Ukey2ClientInit(serializedBytes: message.messageData)
        guard clientInit.version == 1, clientInit.random.count == 32 else {
            throw QSError.protocolViolation("Unsupported key exchange version")
        }
        guard let chosen = clientInit.cipherCommitments.first(where: { $0.handshakeCipher == .p256Sha512 }) else {
            throw QSError.protocolViolation("No supported key exchange cipher")
        }
        guard clientInit.nextProtocol == Ukey2.nextProtocol else {
            throw QSError.protocolViolation("Unsupported encryption protocol")
        }
        commitment = chosen.commitment
        clientInitMessage = data

        let key = P256.KeyAgreement.PrivateKey()
        privateKey = key

        var serverInit = Securegcm_Ukey2ServerInit()
        serverInit.version = 1
        serverInit.random = Data.random(count: 32)
        serverInit.handshakeCipher = .p256Sha512
        serverInit.publicKey = try Ukey2.serializedPublicKey(key.publicKey)

        var reply = Securegcm_Ukey2Message()
        reply.messageType = .serverInit
        reply.messageData = try serverInit.serializedData()
        serverInitMessage = try reply.serializedData()
        framed.send(serverInitMessage)
        log.notice("[\(self.tag, privacy: .public)] key exchange started")
        phase = .awaitingClientFinish
    }

    private func handleClientFinish(_ data: Data) throws {
        let message = try Securegcm_Ukey2Message(serializedBytes: data)
        guard message.messageType == .clientFinish, let privateKey else {
            throw QSError.protocolViolation("Expected the key exchange to finish")
        }
        guard Data(SHA512.hash(data: data)) == commitment else {
            throw QSError.crypto("Key exchange commitment mismatch")
        }
        let finish = try Securegcm_Ukey2ClientFinished(serializedBytes: message.messageData)
        let peerKey = try Ukey2.parsePublicKey(finish.publicKey)
        let keys = try Ukey2.deriveKeys(
            privateKey: privateKey, peerKey: peerKey,
            clientInitMessage: clientInitMessage, serverInitMessage: serverInitMessage, role: .server)
        channel = SecureChannel(keys: keys)
        self.privateKey = nil
        log.notice("[\(self.tag, privacy: .public)] key exchange finished")
        phase = .awaitingConnectionResponse
    }

    private func handleConnectionResponse(_ data: Data) throws {
        let frame = try OfflineFrame(serializedBytes: data)
        guard frame.v1.type == .connectionResponse else {
            throw QSError.protocolViolation("Expected a connection response")
        }
        guard frame.v1.connectionResponse.response != .reject else {
            throw QSError.protocolViolation("The other device rejected the connection")
        }

        var reply = OfflineFrame()
        reply.version = .v1
        reply.v1.type = .connectionResponse
        reply.v1.connectionResponse.response = .accept
        reply.v1.connectionResponse.status = 0
        reply.v1.connectionResponse.osInfo.type = .apple
        framed.send(try reply.serializedData())
        phase = .established
        log.notice("[\(self.tag, privacy: .public)] encrypted channel established")

        try sendSharing { frame in
            frame.type = .pairedKeyEncryption
            frame.pairedKeyEncryption.secretIDHash = Data.random(count: 6)
            frame.pairedKeyEncryption.signedData = Data.random(count: 72)
        }
    }

    private func handleEncrypted(_ data: Data) throws {
        guard let channel else { throw QSError.crypto("No encryption keys") }
        let frame = try OfflineFrame(serializedBytes: try channel.open(data))
        switch frame.v1.type {
        case .payloadTransfer:
            try handlePayloadTransfer(frame.v1.payloadTransfer)
        case .keepAlive:
            if !frame.v1.keepAlive.ack { sendKeepAlive(ack: true) }
        case .disconnection:
            log.notice("[\(self.tag, privacy: .public)] sender sent disconnection")
            if transfer != nil, !finished {
                finish(accepted ? .failed("\(remoteName) disconnected before the transfer finished")
                                : .cancelled(bySender: true))
            }
            close()
        default:
            // Bandwidth upgrades and other optional frames are not needed on Wi-Fi LAN.
            log.notice("[\(self.tag, privacy: .public)] ignoring offline frame type \(frame.v1.type.rawValue, privacy: .public)")
        }
    }

    private func handlePayloadTransfer(_ payload: Location_Nearby_Connections_PayloadTransferFrame) throws {
        let header = payload.payloadHeader
        switch payload.packetType {
        case .control:
            let event = payload.controlMessage.event
            log.notice("[\(self.tag, privacy: .public)] payload control event \(event.rawValue, privacy: .public) for payload \(header.id, privacy: .public)")
            if event == .payloadCanceled || event == .payloadError, transfer != nil, !finished {
                finish(.cancelled(bySender: true))
                close()
            }
        case .data:
            let chunk = payload.payloadChunk
            let isLast = chunk.flags & 1 != 0
            switch header.type {
            case .bytes:
                var buffer = bytesPayloads[header.id] ?? Data()
                guard buffer.count + chunk.body.count <= Self.maxBytesPayload else {
                    throw QSError.protocolViolation("Control message is too large")
                }
                buffer.append(chunk.body)
                if isLast {
                    bytesPayloads[header.id] = nil
                    try handleBytesPayload(id: header.id, data: buffer)
                } else {
                    bytesPayloads[header.id] = buffer
                }
            case .file:
                try handleFileChunk(id: header.id, offset: chunk.offset, body: chunk.body, isLast: isLast)
            default:
                break
            }
        default:
            break
        }
    }

    private func handleBytesPayload(id: Int64, data: Data) throws {
        if accepted, id == textPayloadID {
            let text = String(decoding: data, as: UTF8.self)
            textReceived = true
            if let transfer {
                DispatchQueue.main.async { transfer.text = text }
            }
            checkCompletion()
            return
        }
        if accepted, let slot = slots[id], !slot.done {
            // Small files can arrive whole as a bytes payload instead of file chunks.
            log.notice("[\(self.tag, privacy: .public)] file payload \(id, privacy: .public) arrived as bytes (\(data.count, privacy: .public) bytes)")
            try handleFileChunk(id: id, offset: 0, body: data, isLast: true)
            return
        }
        let frame = try SharingFrame(serializedBytes: data)
        log.notice("[\(self.tag, privacy: .public)] sharing frame type \(frame.v1.type.rawValue, privacy: .public)")
        switch frame.v1.type {
        case .pairedKeyEncryption:
            try sendSharing { frame in
                frame.type = .pairedKeyResult
                frame.pairedKeyResult.status = .unable
            }
        case .pairedKeyResult:
            break
        case .introduction:
            try handleIntroduction(frame.v1.introduction)
        case .cancel:
            if transfer != nil, !finished { finish(.cancelled(bySender: true)) }
            close()
        default:
            break
        }
    }

    private func handleIntroduction(_ introduction: Sharing_Nearby_IntroductionFrame) throws {
        guard transfer == nil, let channel else { return }
        let files = introduction.fileMetadata.map {
            IncomingFile(id: $0.payloadID, name: FileStore.sanitize($0.name), size: $0.size,
                         mimeType: $0.mimeType, attachmentHash: $0.attachmentHash)
        }
        let textMeta = introduction.textMetadata.first
        log.notice("[\(self.tag, privacy: .public)] introduction: \(files.count, privacy: .public) file(s) sizes \(files.map(\.size), privacy: .public) ids \(files.map(\.id), privacy: .public), \(introduction.textMetadata.count, privacy: .public) text, \(introduction.wifiCredentialsMetadata.count, privacy: .public) wifi, \(introduction.appMetadata.count, privacy: .public) app, \(introduction.streamMetadata.count, privacy: .public) stream")
        guard !files.isEmpty || textMeta != nil else {
            try sendSharing { frame in
                frame.type = .response
                frame.connectionResponse.status = .unsupportedAttachmentType
            }
            sendDisconnectionAndClose()
            return
        }

        var kind: TextKind?
        if let textMeta, files.isEmpty {
            textPayloadID = textMeta.payloadID
            switch textMeta.type {
            case .url: kind = .url
            case .address: kind = .address
            case .phoneNumber: kind = .phoneNumber
            default: kind = .text
            }
        }

        let transfer = IncomingTransfer(
            deviceName: remoteName, deviceType: remoteType, pin: channel.pin, files: files,
            textKind: kind, textTitle: kind == nil ? nil : textMeta?.textTitle)
        transfer.acceptHandler = { [weak self] in self?.queue.async { self?.accept() } }
        transfer.declineHandler = { [weak self] in self?.queue.async { self?.decline() } }
        transfer.cancelHandler = { [weak self] in self?.queue.async { self?.cancelByUser() } }
        self.transfer = transfer
        let announce = onTransfer
        DispatchQueue.main.async { announce?(transfer) }
    }

    // MARK: - User decisions

    private func accept() {
        guard phase == .established, let transfer, !accepted, !finished else { return }
        do {
            try store.prepare()
            var response = Sharing_Nearby_ConnectionResponseFrame()
            response.status = .accept
            var needed: Int64 = 0

            for file in transfer.files {
                let offered = environment.resumeEnabled ? store.resumableSize(for: file) : 0
                slots[file.id] = FileSlot(file: file, partialURL: store.partialURL(for: file), offered: offered)
                needed += max(0, file.size - offered)
                if offered > 0 {
                    // Tell the sender how much of this file survived an earlier attempt. Senders
                    // that support resumption continue from there; others simply start at zero.
                    var details = Sharing_Nearby_AttachmentDetails()
                    details.type = .file
                    details.fileAttachmentDetails.receiverExistingFileSize = offered
                    response.attachmentDetails[file.attachmentHash] = details
                }
            }

            if let available = store.availableBytes(), available < needed {
                try sendSharing { frame in
                    frame.type = .response
                    frame.connectionResponse.status = .notEnoughSpace
                }
                finish(.failed("Not enough free disk space"))
                sendDisconnectionAndClose()
                return
            }

            try sendSharing { frame in
                frame.type = .response
                frame.connectionResponse = response
            }
            accepted = true
            log.notice("[\(self.tag, privacy: .public)] accepted; resume offers: \(response.attachmentDetails.count, privacy: .public)")
            lastProgressAt = Date()
            publish(transfer) { $0.state = .receiving }
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func decline() {
        guard phase == .established, transfer != nil, !accepted, !finished else { return }
        try? sendSharing { frame in
            frame.type = .response
            frame.connectionResponse.status = .reject
        }
        finish(.declined)
        sendDisconnectionAndClose()
    }

    private func cancelByUser() {
        guard phase == .established, transfer != nil, !finished else { return }
        try? sendSharing { frame in frame.type = .cancel }
        finish(.cancelled(bySender: false))
        sendDisconnectionAndClose()
    }

    // MARK: - Files

    private func handleFileChunk(id: Int64, offset: Int64, body: Data, isLast: Bool) throws {
        guard accepted, !finished, let slot = slots[id], !slot.done else {
            if slots[id] == nil {
                log.notice("[\(self.tag, privacy: .public)] file data for unknown payload \(id, privacy: .public) (accepted: \(self.accepted, privacy: .public))")
            }
            return
        }

        if !slot.started {
            slot.started = true
            log.notice("[\(self.tag, privacy: .public)] first data for payload \(id, privacy: .public) at offset \(offset, privacy: .public), \(body.count, privacy: .public) bytes (offered \(slot.offered, privacy: .public))")
            var startAt: Int64 = 0
            if slot.offered > 0, offset > 0, offset <= slot.offered {
                startAt = offset // The sender is continuing an earlier attempt.
            } else if offset != 0 {
                throw QSError.protocolViolation("File data started at an unexpected position")
            }
            let fm = FileManager.default
            if startAt == 0 {
                try? fm.removeItem(at: slot.partialURL)
                guard fm.createFile(atPath: slot.partialURL.path, contents: nil) else {
                    throw QSError.io("Could not create a file in \(environment.destination.lastPathComponent)")
                }
            }
            let handle = try FileHandle(forWritingTo: slot.partialURL)
            try handle.truncate(atOffset: UInt64(startAt))
            try handle.seek(toOffset: UInt64(startAt))
            slot.handle = handle
            slot.written = startAt
            receivedBytes += startAt
            lastProgressBytes += startAt
            if startAt > 0, let transfer {
                resumedBytes += startAt
                let resumed = resumedBytes
                DispatchQueue.main.async { transfer.resumedBytes = resumed }
            }
        }

        guard offset == slot.written else {
            throw QSError.protocolViolation("File data arrived out of order")
        }
        if !body.isEmpty {
            guard slot.file.size <= 0 || slot.written + Int64(body.count) <= slot.file.size else {
                throw QSError.protocolViolation("Received more data than the file's announced size")
            }
            try slot.handle?.write(contentsOf: body)
            slot.written += Int64(body.count)
            receivedBytes += Int64(body.count)
        }

        if isLast {
            guard slot.file.size <= 0 || slot.written == slot.file.size else {
                throw QSError.io("\(slot.file.name) arrived incomplete")
            }
            try slot.handle?.close()
            slot.handle = nil
            let saved = try store.finalize(partial: slot.partialURL, name: slot.file.name)
            slot.done = true
            if let transfer {
                DispatchQueue.main.async { transfer.savedFiles.append(saved) }
            }
            publishProgress(force: true)
            checkCompletion()
        } else {
            publishProgress(force: false)
        }
    }

    private func checkCompletion() {
        guard accepted, !finished else { return }
        guard slots.values.allSatisfy(\.done), textPayloadID == nil || textReceived else { return }
        finish(.completed)
        sendDisconnectionAndClose()
    }

    private func publishProgress(force: Bool) {
        guard let transfer else { return }
        let now = Date()
        let elapsed = now.timeIntervalSince(lastProgressAt)
        guard force || elapsed >= 0.2 else { return }
        if elapsed > 0.05 {
            let instantaneous = Double(receivedBytes - lastProgressBytes) / elapsed
            speed = speed == 0 ? instantaneous : speed * 0.7 + instantaneous * 0.3
            lastProgressAt = now
            lastProgressBytes = receivedBytes
        }
        let bytes = receivedBytes
        let currentSpeed = speed
        DispatchQueue.main.async {
            transfer.bytesReceived = bytes
            transfer.bytesPerSecond = currentSpeed
        }
    }

    // MARK: - Ending

    /// Settles the transfer's final state and deals with any half-written files.
    private func finish(_ state: TransferState) {
        guard !finished else { return }
        finished = true
        log.notice("[\(self.tag, privacy: .public)] transfer finished: \(String(describing: state), privacy: .public) after \(self.receivedBytes, privacy: .public) bytes")

        var keepPartials = false
        if case .failed = state { keepPartials = environment.resumeEnabled }

        for slot in slots.values where !slot.done {
            try? slot.handle?.close()
            slot.handle = nil
            guard slot.started else { continue } // Untouched; an earlier partial stays as it was.
            // Keep a partial only if it can be offered again and this attempt added to it.
            // A resume offer that made no progress is dropped so the next attempt starts clean.
            let worthKeeping = keepPartials && slot.file.attachmentHash != 0 && slot.written > slot.offered
            if !worthKeeping {
                try? FileManager.default.removeItem(at: slot.partialURL)
            }
        }
        store.cleanUp()

        guard let transfer else { return }
        let bytes = receivedBytes
        publish(transfer) {
            if state == .completed { $0.bytesReceived = max(bytes, $0.totalBytes) } else { $0.bytesReceived = bytes }
            $0.bytesPerSecond = 0
            $0.finishedAt = Date()
            $0.state = state
        }
    }

    private func fail(_ message: String) {
        log.error("[\(self.tag, privacy: .public)] failing: \(message, privacy: .public)")
        if transfer != nil, !finished {
            finish(.failed(message))
        }
        close()
    }

    private func sendDisconnectionAndClose() {
        guard phase == .established else { return close() }
        var frame = OfflineFrame()
        frame.version = .v1
        frame.v1.type = .disconnection
        if let data = try? frame.serializedData(), let sealed = try? channel?.seal(data) {
            framed.send(sealed) { [weak self] in self?.close() }
            queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.close() }
        } else {
            close()
        }
    }

    private func close() {
        guard phase != .closed else { return }
        framed.close()
    }

    private func connectionClosed(_ error: Error?) {
        log.notice("[\(self.tag, privacy: .public)] connection closed in phase \(String(describing: self.phase), privacy: .public): \(error.map { String(describing: $0) } ?? "clean", privacy: .public)")
        phase = .closed
        timer?.cancel()
        timer = nil
        if transfer != nil, !finished {
            finish(accepted ? .failed("The connection to \(remoteName) was lost")
                            : .cancelled(bySender: true))
        }
        onClosed?()
        onClosed = nil
    }

    private func tick() {
        let now = Date()
        switch phase {
        case .closed:
            return
        case .established:
            if now.timeIntervalSince(lastKeepAliveSent) >= Self.keepAliveInterval {
                sendKeepAlive(ack: false)
            }
            // Flush throttled progress so the UI is accurate (and speed drops) when data pauses.
            if accepted, !finished { publishProgress(force: true) }
            if accepted, !finished, now.timeIntervalSince(lastReceived) > Self.stallTimeout {
                fail("The transfer from \(remoteName) stalled")
            } else if transfer == nil, now.timeIntervalSince(openedAt) > Self.handshakeTimeout {
                close()
            }
        default:
            if now.timeIntervalSince(openedAt) > Self.handshakeTimeout { close() }
        }
    }

    // MARK: - Sending

    private func sendKeepAlive(ack: Bool) {
        lastKeepAliveSent = Date()
        var frame = OfflineFrame()
        frame.version = .v1
        frame.v1.type = .keepAlive
        frame.v1.keepAlive.ack = ack
        try? sendEncrypted(frame)
    }

    private func sendEncrypted(_ frame: OfflineFrame) throws {
        guard let channel, phase == .established else { return }
        framed.send(try channel.seal(try frame.serializedData()))
    }

    /// Sends a sharing-layer frame as a "bytes" payload: the data, then an empty last chunk.
    private func sendSharing(_ build: (inout Sharing_Nearby_V1Frame) -> Void) throws {
        var sharing = SharingFrame()
        sharing.version = .v1
        build(&sharing.v1)
        let data = try sharing.serializedData()
        let id = Int64.random(in: 1...Int64.max)

        var frame = OfflineFrame()
        frame.version = .v1
        frame.v1.type = .payloadTransfer
        frame.v1.payloadTransfer.packetType = .data
        frame.v1.payloadTransfer.payloadHeader.id = id
        frame.v1.payloadTransfer.payloadHeader.type = .bytes
        frame.v1.payloadTransfer.payloadHeader.totalSize = Int64(data.count)
        frame.v1.payloadTransfer.payloadHeader.isSensitive = false
        frame.v1.payloadTransfer.payloadChunk.offset = 0
        frame.v1.payloadTransfer.payloadChunk.flags = 0
        frame.v1.payloadTransfer.payloadChunk.body = data
        try sendEncrypted(frame)

        frame.v1.payloadTransfer.payloadChunk.offset = Int64(data.count)
        frame.v1.payloadTransfer.payloadChunk.flags = 1
        frame.v1.payloadTransfer.payloadChunk.body = Data()
        try sendEncrypted(frame)
    }

    private func publish(_ transfer: IncomingTransfer, _ change: @escaping (IncomingTransfer) -> Void) {
        let changed = onTransferChanged
        DispatchQueue.main.async {
            change(transfer)
            changed?(transfer)
        }
    }
}
