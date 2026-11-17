import Combine
import Foundation
import Network
import os

/// Advertises this Mac as a Quick Share target and accepts incoming transfers.
///
/// Designed to be left running: it restarts its listener when the network changes or the
/// listener fails, re-announces itself when a nearby phone starts looking for targets, and
/// keeps the Mac awake while a transfer is in flight.
public final class QuickShareReceiver: ObservableObject, @unchecked Sendable {
    public struct Configuration: Equatable, Sendable {
        public var deviceName: String
        public var destination: URL
        /// 4 alphanumeric characters. Keep it stable across launches so phones don't see duplicates.
        public var endpointID: String
        /// Offer partially received files to the sender so an interrupted transfer can continue.
        public var resumeEnabled: Bool
        /// TCP port to listen on. Keeping it the same across launches means a phone holding a
        /// cached address for this Mac still reaches it. nil or unavailable = pick any free port.
        public var preferredPort: UInt16?

        public init(deviceName: String, destination: URL, endpointID: String? = nil,
                    resumeEnabled: Bool = true, preferredPort: UInt16? = nil) {
            self.preferredPort = preferredPort
            self.deviceName = deviceName
            self.destination = destination
            if let endpointID, EndpointID.isValid(endpointID) {
                self.endpointID = endpointID
            } else {
                self.endpointID = EndpointID.generate()
            }
            self.resumeEnabled = resumeEnabled
        }
    }

    public enum Status: Equatable, Sendable {
        case stopped
        case starting
        /// Listening and visible to phones on the same network.
        case ready(port: UInt16)
        /// Not currently reachable; the receiver keeps retrying on its own.
        case unavailable(String)
    }

    public static let serviceType = "_FC9F5ED42C8A._tcp"

    @Published public private(set) var status: Status = .stopped
    /// Newest first.
    @Published public private(set) var transfers: [IncomingTransfer] = []
    /// True while a nearby phone has its Quick Share sheet open (needs Bluetooth permission).
    @Published public private(set) var senderNearby = false

    /// Called on the main queue when a device asks to send something.
    public var onRequest: ((IncomingTransfer) -> Void)?
    /// Called on the main queue when a transfer reaches a final state.
    public var onFinished: ((IncomingTransfer) -> Void)?

    public private(set) var configuration: Configuration

    private let log = Logger(subsystem: "app.qshare.mac", category: "receiver")
    private let queue = DispatchQueue(label: "qshare.receiver")
    private var running = false
    private var listener: NWListener?
    private var listenerGeneration = 0
    private var service: NWListener.Service?
    private var connections: [UUID: InboundConnection] = [:]
    private var pathMonitor: NWPathMonitor?
    private var pathSignature: String?
    private var networkAvailable = true
    private var retryDelay: TimeInterval = 1
    /// Consecutive failures to bind the preferred port; after a few, any free port is used.
    private var preferredPortFailures = 0
    private var usingPreferredPort = false
    private var restartWork: DispatchWorkItem?
    private var watchdog: DispatchSourceTimer?
    private var lastAnnounce = Date.distantPast
    private var bluetooth: NearbySenderScanner?
    private var nearbyResetWork: DispatchWorkItem?
    private var activity: NSObjectProtocol?

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    // MARK: - Control

    public func start() {
        queue.async {
            guard !self.running else { return }
            self.running = true
            self.startPathMonitor()
            self.startWatchdog()
            self.startBluetooth()
            self.startListener()
            FileStore(destination: self.configuration.destination).cleanUp()
        }
    }

    public func stop() {
        queue.async {
            guard self.running else { return }
            self.running = false
            self.restartWork?.cancel()
            self.watchdog?.cancel()
            self.watchdog = nil
            self.pathMonitor?.cancel()
            self.pathMonitor = nil
            self.bluetooth?.stop()
            self.bluetooth = nil
            self.tearDownListener()
            self.connections.values.forEach { $0.abort() }
            self.setStatus(.stopped)
        }
    }

    /// Rebuilds the listener and advertisement. Transfers already in flight are not affected.
    public func restart() {
        queue.async {
            guard self.running else { return }
            self.retryDelay = 1
            self.preferredPortFailures = 0
            self.startListener()
        }
    }

    public func update(_ configuration: Configuration) {
        queue.async {
            guard configuration != self.configuration else { return }
            let needsRestart = configuration.deviceName != self.configuration.deviceName
                || configuration.endpointID != self.configuration.endpointID
            self.configuration = configuration
            if needsRestart, self.running { self.startListener() }
        }
    }

    /// Removes finished transfers from the list.
    public func clearFinished() {
        DispatchQueue.main.async {
            self.transfers.removeAll { $0.state.isFinished }
        }
    }

    public func remove(_ transfer: IncomingTransfer) {
        DispatchQueue.main.async {
            guard transfer.state.isFinished else { return }
            self.transfers.removeAll { $0.id == transfer.id }
        }
    }

    // MARK: - Listener

    private func startListener() {
        restartWork?.cancel()
        restartWork = nil
        tearDownListener()
        guard running else { return }
        setStatus(.starting)

        listenerGeneration += 1
        let generation = listenerGeneration
        do {
            let tcp = NWProtocolTCP.Options()
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 10
            tcp.keepaliveInterval = 5
            tcp.keepaliveCount = 3
            tcp.noDelay = true
            let parameters = NWParameters(tls: nil, tcp: tcp)
            parameters.allowLocalEndpointReuse = true

            let listener: NWListener
            if preferredPortFailures < 4, let preferred = configuration.preferredPort,
               let port = NWEndpoint.Port(rawValue: preferred), preferred != 0 {
                listener = try NWListener(using: parameters, on: port)
                usingPreferredPort = true
            } else {
                listener = try NWListener(using: parameters)
                usingPreferredPort = false
            }
            let info = EndpointInfo(deviceType: .laptop, name: configuration.deviceName).serialized()
            let service = NWListener.Service(
                name: EndpointID.serviceName(for: configuration.endpointID),
                type: Self.serviceType,
                txtRecord: NWTXTRecord(["n": info.urlSafeBase64()]))
            self.service = service
            listener.service = service

            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, self.listenerGeneration == generation else { return }
                switch state {
                case .ready:
                    self.retryDelay = 1
                    if self.usingPreferredPort { self.preferredPortFailures = 0 }
                    let port = listener?.port?.rawValue ?? 0
                    self.setStatus(self.networkAvailable ? .ready(port: port) : .unavailable("Not connected to a network"))
                case .waiting(let error):
                    self.setStatus(.unavailable(Self.describe(error)))
                    self.scheduleRestart()
                case .failed(let error):
                    if self.usingPreferredPort, case .posix(let code) = error, code == .EADDRINUSE {
                        // Often just the previous listener still letting go; retry shortly.
                        self.preferredPortFailures += 1
                        self.retryDelay = min(self.retryDelay, 0.5)
                        self.log.notice("preferred port busy (attempt \(self.preferredPortFailures, privacy: .public))")
                    }
                    self.setStatus(.unavailable(Self.describe(error)))
                    self.scheduleRestart()
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self, self.listenerGeneration == generation else {
                    connection.cancel()
                    return
                }
                self.accept(connection)
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            setStatus(.unavailable(error.localizedDescription))
            scheduleRestart()
        }
    }

    private func tearDownListener() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
    }

    private func scheduleRestart() {
        guard running, restartWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.restartWork = nil
            self.startListener()
        }
        restartWork = work
        queue.asyncAfter(deadline: .now() + retryDelay, execute: work)
        retryDelay = min(retryDelay * 2, 30)
    }

    /// Publishes the mDNS record again so a phone that is searching right now sees it promptly.
    private func reannounce() {
        guard running, let listener, let service, case .ready = listener.state else { return }
        guard Date().timeIntervalSince(lastAnnounce) > 20 else { return }
        lastAnnounce = Date()
        listener.service = nil
        listener.service = service
    }

    /// Test hook: re-announce immediately.
    func announceNow() {
        queue.async { self.reannounce() }
    }

    private func accept(_ connection: NWConnection) {
        let inbound = InboundConnection(
            connection: connection,
            environment: .init(destination: configuration.destination, resumeEnabled: configuration.resumeEnabled))
        let id = UUID()
        connections[id] = inbound
        inbound.onClosed = { [weak self] in
            self?.queue.async { self?.connections[id] = nil }
        }
        inbound.onTransfer = { [weak self] transfer in
            guard let self else { return }
            self.transfers.insert(transfer, at: 0)
            self.onRequest?(transfer)
        }
        inbound.onTransferChanged = { [weak self] transfer in
            guard let self else { return }
            self.updateActivity()
            if transfer.state.isFinished { self.onFinished?(transfer) }
        }
        inbound.start()
    }

    // MARK: - Self-healing

    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self, self.running else { return }
            let usable = path.status == .satisfied
            let signature = path.availableInterfaces.map(\.name).sorted().joined(separator: ",")
                + "|" + path.gateways.map { "\($0)" }.sorted().joined(separator: ",")
            let first = self.pathSignature == nil
            let changed = signature != self.pathSignature || usable != self.networkAvailable
            self.pathSignature = signature
            self.networkAvailable = usable
            guard changed, !first else { return }
            if usable {
                // New Wi-Fi network, new address, or back online: advertise from scratch.
                self.retryDelay = 1
                self.restartWork?.cancel()
                self.restartWork = nil
                self.scheduleRestart()
            } else {
                self.setStatus(.unavailable("Not connected to a network"))
            }
        }
        monitor.start(queue: queue)
        pathMonitor = monitor
    }

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            guard let self, self.running, self.restartWork == nil else { return }
            if let listener = self.listener, case .ready = listener.state { return }
            if let listener = self.listener, case .setup = listener.state { return }
            self.startListener()
        }
        timer.resume()
        watchdog = timer
    }

    private func startBluetooth() {
        // Touching Bluetooth without a usage description terminates the process, so only
        // scan when the host app declares one.
        guard Bundle.main.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription") != nil else { return }
        let scanner = NearbySenderScanner { [weak self] in
            guard let self else { return }
            self.queue.async {
                self.reannounce()
                self.nearbyResetWork?.cancel()
                let reset = DispatchWorkItem {
                    DispatchQueue.main.async { self.senderNearby = false }
                }
                self.nearbyResetWork = reset
                self.queue.asyncAfter(deadline: .now() + 12, execute: reset)
            }
            DispatchQueue.main.async {
                if !self.senderNearby { self.senderNearby = true }
            }
        }
        scanner.start()
        bluetooth = scanner
    }

    /// Keeps the Mac from idle-sleeping (and the app from being napped) while receiving.
    private func updateActivity() {
        let receiving = transfers.contains { $0.state == .receiving }
        if receiving, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled],
                reason: "Receiving files over Quick Share")
        } else if !receiving, let token = activity {
            ProcessInfo.processInfo.endActivity(token)
            activity = nil
        }
    }

    private func setStatus(_ status: Status) {
        log.notice("status: \(String(describing: status), privacy: .public)")
        DispatchQueue.main.async {
            if self.status != status { self.status = status }
        }
    }

    private static func describe(_ error: NWError) -> String {
        if case .dns(let code) = error, code == -65570 {
            return "Local network access is turned off for this app. Allow it in System Settings › Privacy & Security › Local Network."
        }
        return error.localizedDescription
    }
}
