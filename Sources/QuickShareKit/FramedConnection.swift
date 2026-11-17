import Foundation
import Network

/// Reads and writes length-prefixed frames (4-byte big-endian length) over a TCP connection.
/// All callbacks are delivered on the queue passed to `start`.
final class FramedConnection {
    /// Largest frame we will accept. File chunks are well under 1 MB in practice.
    static let maxFrameSize = 32 * 1024 * 1024

    let connection: NWConnection
    var onFrame: ((Data) -> Void)?
    /// Called once when the connection ends, with an error unless we closed it ourselves.
    var onClose: ((Error?) -> Void)?

    private var closed = false

    init(connection: NWConnection) {
        self.connection = connection
    }

    func start(queue: DispatchQueue) {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.readHeader()
            case .failed(let error):
                self.finish(error)
            case .cancelled:
                self.finish(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func send(_ frame: Data, completion: (() -> Void)? = nil) {
        guard !closed else { return }
        var packet = Data(capacity: frame.count + 4)
        var length = UInt32(frame.count).bigEndian
        withUnsafeBytes(of: &length) { packet.append(contentsOf: $0) }
        packet.append(frame)
        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            if let error {
                self?.finish(error)
            } else {
                completion?()
            }
        })
    }

    /// Closes the connection. `onClose` fires with the given error (nil = clean shutdown).
    func close(error: Error? = nil) {
        finish(error)
    }

    private func finish(_ error: Error?) {
        guard !closed else { return }
        closed = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        onClose?(error)
        onFrame = nil
        onClose = nil
    }

    private func readHeader() {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            guard let data, data.count == 4 else {
                self.finish(error ?? (isComplete ? QSError.io("The other device closed the connection") : QSError.io("Read failed")))
                return
            }
            let length = data.reduce(0) { ($0 << 8) | Int($1) }
            guard length > 0, length <= Self.maxFrameSize else {
                self.finish(QSError.protocolViolation("Invalid frame length \(length)"))
                return
            }
            self.readBody(length: length)
        }
    }

    private func readBody(length: Int) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            guard let data, data.count == length else {
                self.finish(error ?? (isComplete ? QSError.io("The other device closed the connection") : QSError.io("Read failed")))
                return
            }
            self.onFrame?(data)
            if !self.closed { self.readHeader() }
        }
    }
}
