import Combine
import Foundation

public struct IncomingFile: Identifiable, Sendable, Equatable {
    /// Payload identifier within the connection.
    public let id: Int64
    public let name: String
    public let size: Int64
    public let mimeType: String
    /// Stable identifier the sender assigns to the same file across attempts (0 if not provided).
    let attachmentHash: Int64
}

public enum TextKind: Sendable, Equatable {
    case text, url, address, phoneNumber
}

public enum TransferState: Equatable, Sendable {
    case awaitingApproval
    case receiving
    case completed
    case declined
    /// Cancelled by either side. `bySender` is true if the phone cancelled.
    case cancelled(bySender: Bool)
    case failed(String)

    public var isFinished: Bool {
        switch self {
        case .awaitingApproval, .receiving: return false
        default: return true
        }
    }
}

/// One incoming share from another device. Properties change on the main queue.
public final class IncomingTransfer: ObservableObject, Identifiable, @unchecked Sendable {
    public let id = UUID()
    public let deviceName: String
    public let deviceType: DeviceType
    /// 4-digit code that should match the one shown on the sending device.
    public let pin: String
    public let files: [IncomingFile]
    public let textKind: TextKind?
    public let textTitle: String?
    public let totalBytes: Int64
    public let startedAt = Date()

    @Published public internal(set) var state: TransferState = .awaitingApproval
    @Published public internal(set) var bytesReceived: Int64 = 0
    @Published public internal(set) var bytesPerSecond: Double = 0
    /// Bytes that were already on disk from an earlier interrupted attempt and did not need re-sending.
    @Published public internal(set) var resumedBytes: Int64 = 0
    @Published public internal(set) var savedFiles: [URL] = []
    @Published public internal(set) var text: String?
    @Published public internal(set) var finishedAt: Date?

    var acceptHandler: (() -> Void)?
    var declineHandler: (() -> Void)?
    var cancelHandler: (() -> Void)?

    init(deviceName: String, deviceType: DeviceType, pin: String, files: [IncomingFile],
         textKind: TextKind?, textTitle: String?) {
        self.deviceName = deviceName
        self.deviceType = deviceType
        self.pin = pin
        self.files = files
        self.textKind = textKind
        self.textTitle = textTitle
        self.totalBytes = files.reduce(0) { $0 + max(0, $1.size) }
    }

    public var fractionCompleted: Double {
        guard totalBytes > 0 else { return state == .completed ? 1 : 0 }
        return min(1, Double(bytesReceived) / Double(totalBytes))
    }

    /// Short human description of what is being sent, e.g. "IMG_1234.jpg" or "3 files".
    public var summary: String {
        if files.count == 1 { return files[0].name }
        if files.count > 1 { return "\(files.count) files" }
        switch textKind {
        case .url: return "Link"
        case .address: return "Address"
        case .phoneNumber: return "Phone number"
        default: return "Text"
        }
    }

    public func accept() {
        guard state == .awaitingApproval else { return }
        acceptHandler?()
    }

    public func decline() {
        guard state == .awaitingApproval else { return }
        declineHandler?()
    }

    public func cancel() {
        guard state == .receiving else { return }
        cancelHandler?()
    }
}
