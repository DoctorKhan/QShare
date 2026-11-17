import AppKit
import Combine
import QuickShareKit
import ServiceManagement
import UserNotifications

enum AutoAcceptMode: String, CaseIterable, Identifiable {
    case ask, trusted, everyone
    var id: String { rawValue }

    var title: String {
        switch self {
        case .ask: return "Ask every time"
        case .trusted: return "Devices I've trusted"
        case .everyone: return "Everyone on this network"
        }
    }
}

/// App state: settings, the receiver, and everything that reacts to transfers
/// (notifications, clipboard, auto-accept).
final class AppModel: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    private enum Key {
        static let deviceName = "deviceName"
        static let destination = "destinationPath"
        static let endpointID = "endpointID"
        static let autoAccept = "autoAcceptMode"
        static let trusted = "trustedDevices"
        static let resume = "resumeEnabled"
        static let port = "listenPort"
        static let reveal = "revealAfterReceiving"
    }

    private enum Action {
        static let accept = "ACCEPT"
        static let decline = "DECLINE"
        static let openLink = "OPEN_LINK"
        static let requestCategory = "REQUEST"
        static let linkCategory = "LINK"
    }

    let receiver: QuickShareReceiver
    private let defaults = UserDefaults.standard
    private var cancellables: Set<AnyCancellable> = []
    private var transferObservers: [UUID: AnyCancellable] = [:]

    @Published var deviceName: String { didSet { defaults.set(deviceName, forKey: Key.deviceName); applyConfiguration() } }
    @Published var destination: URL { didSet { defaults.set(destination.path, forKey: Key.destination); applyConfiguration() } }
    @Published var autoAccept: AutoAcceptMode { didSet { defaults.set(autoAccept.rawValue, forKey: Key.autoAccept) } }
    @Published var trustedDevices: [String] { didSet { defaults.set(trustedDevices, forKey: Key.trusted) } }
    @Published var resumeEnabled: Bool { didSet { defaults.set(resumeEnabled, forKey: Key.resume); applyConfiguration() } }
    @Published var launchAtLogin: Bool = false
    @Published var launchAtLoginError: String?
    /// False when macOS won't show this app's notifications (the floating panel still works).
    @Published var notificationsAllowed = true
    /// Pointer is over the floating panel; finished items wait until it leaves.
    var panelHovered = false
    @Published var revealAfterReceiving = UserDefaults.standard.bool(forKey: "revealAfterReceiving") {
        didSet { defaults.set(revealAfterReceiving, forKey: Key.reveal) }
    }
    /// Transfers shown in the floating panel: waiting for an answer, in progress, or just finished.
    @Published private(set) var panelTransfers: [IncomingTransfer] = []
    private lazy var panel = TransferPanelController(model: self)

    private let endpointID: String
    private var listenPort: UInt16?

    override init() {
        let storedName = defaults.string(forKey: Key.deviceName) ?? ""
        let name = storedName.isEmpty ? (Host.current().localizedName ?? "Mac") : storedName

        var folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        if let path = defaults.string(forKey: Key.destination), FileManager.default.fileExists(atPath: path) {
            folder = URL(fileURLWithPath: path, isDirectory: true)
        }
        let resume = defaults.object(forKey: Key.resume) as? Bool ?? true

        let configuration = QuickShareReceiver.Configuration(
            deviceName: name, destination: folder,
            endpointID: defaults.string(forKey: Key.endpointID), resumeEnabled: resume,
            preferredPort: UInt16(exactly: defaults.integer(forKey: Key.port)))
        deviceName = name
        destination = folder
        resumeEnabled = resume
        autoAccept = AutoAcceptMode(rawValue: defaults.string(forKey: Key.autoAccept) ?? "") ?? .ask
        trustedDevices = defaults.stringArray(forKey: Key.trusted) ?? []
        endpointID = configuration.endpointID
        defaults.set(configuration.endpointID, forKey: Key.endpointID)
        receiver = QuickShareReceiver(configuration: configuration)
        super.init()

        launchAtLogin = SMAppService.mainApp.status == .enabled
        receiver.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        receiver.onRequest = { [weak self] transfer in self?.handleRequest(transfer) }
        // Remember the port the first launch got, and keep using it.
        receiver.$status
            .sink { [weak self] status in
                guard let self, case .ready(let port) = status, port != 0 else { return }
                if self.defaults.integer(forKey: Key.port) != Int(port) {
                    self.defaults.set(Int(port), forKey: Key.port)
                    self.listenPort = port
                }
            }
            .store(in: &cancellables)
    }

    func start() {
        setUpNotifications()
        receiver.start()
        // After sleep the old listener and mDNS registration can be stale; rebuild them.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.receiver.restart()
        }
    }

    private func applyConfiguration() {
        let name = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        receiver.update(.init(
            deviceName: name.isEmpty ? (Host.current().localizedName ?? "Mac") : name,
            destination: destination, endpointID: endpointID, resumeEnabled: resumeEnabled,
            preferredPort: listenPort ?? UInt16(exactly: defaults.integer(forKey: Key.port))))
    }

    // MARK: - Derived state

    var pendingCount: Int { receiver.transfers.filter { $0.state == .awaitingApproval }.count }
    var isReceiving: Bool { receiver.transfers.contains { $0.state == .receiving } }

    var menuBarSymbol: String {
        if pendingCount > 0 { return "arrow.down.circle.badge.clock" }
        if isReceiving { return "arrow.down.circle.fill" }
        if case .unavailable = receiver.status { return "arrow.down.circle.dotted" }
        return "arrow.down.circle"
    }

    // MARK: - Settings actions

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = destination
        panel.prompt = "Choose"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            destination = url
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func trust(_ deviceName: String) {
        if !trustedDevices.contains(deviceName) { trustedDevices.append(deviceName) }
        if autoAccept == .ask { autoAccept = .trusted }
    }

    func untrust(_ deviceName: String) {
        trustedDevices.removeAll { $0 == deviceName }
    }

    // MARK: - Transfer actions

    func open(_ transfer: IncomingTransfer) {
        if transfer.savedFiles.count == 1 {
            NSWorkspace.shared.open(transfer.savedFiles[0])
        } else if !transfer.savedFiles.isEmpty {
            reveal(transfer)
        } else if let url = link(in: transfer) {
            NSWorkspace.shared.open(url)
        }
    }

    func reveal(_ transfer: IncomingTransfer) {
        let existing = transfer.savedFiles.filter { FileManager.default.fileExists(atPath: $0.path) }
        if existing.isEmpty {
            NSWorkspace.shared.open(destination)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(existing)
        }
    }

    func copyText(_ transfer: IncomingTransfer) {
        guard let text = transfer.text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// A web link carried by a text transfer, if it is one. Only http(s) is ever opened.
    func link(in transfer: IncomingTransfer) -> URL? {
        guard transfer.textKind == .url, let text = transfer.text,
              let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }

    // MARK: - Reacting to transfers

    private func handleRequest(_ transfer: IncomingTransfer) {
        transferObservers[transfer.id] = transfer.$state
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak transfer] state in
                guard let self, let transfer else { return }
                self.objectWillChange.send()
                self.stateChanged(transfer, to: state)
            }

        panelTransfers.append(transfer)
        panel.refresh()

        let trusted = trustedDevices.contains(transfer.deviceName)
        if autoAccept == .everyone || (autoAccept == .trusted && trusted) {
            transfer.accept()
        } else {
            NSSound(named: "Glass")?.play()
            notifyRequest(transfer)
        }
    }

    private func stateChanged(_ transfer: IncomingTransfer, to state: TransferState) {
        let center = UNUserNotificationCenter.current()
        if state != .awaitingApproval {
            center.removeDeliveredNotifications(withIdentifiers: [requestID(transfer)])
        }
        panel.refresh()
        guard state.isFinished else { return }
        transferObservers[transfer.id] = nil
        // Leave the result up long enough to act on it. It never closes while the pointer is over it.
        var linger: TimeInterval = 8
        if state == .completed { linger = 30 }
        if case .failed = state { linger = 30 }
        if state == .declined || state == .cancelled(bySender: false) { linger = 0.5 }
        dismissLater(transfer, after: linger)

        if state == .completed, revealAfterReceiving, !transfer.savedFiles.isEmpty {
            reveal(transfer)
        }

        switch state {
        case .completed:
            if transfer.files.isEmpty {
                // Text arrives just before completion; give the property a beat to land.
                DispatchQueue.main.async {
                    self.copyText(transfer)
                    let isLink = self.link(in: transfer) != nil
                    self.notify(
                        id: transfer.id.uuidString,
                        title: "\(transfer.summary) from \(transfer.deviceName)",
                        body: "Copied to the clipboard" + (transfer.text.map { ": \($0.prefix(120))" } ?? ""),
                        category: isLink ? Action.linkCategory : nil, transfer: transfer)
                }
            } else {
                var body = "Saved to \(destination.lastPathComponent)"
                if transfer.resumedBytes > 0 {
                    let resumed = ByteCountFormatter.string(fromByteCount: transfer.resumedBytes, countStyle: .file)
                    body += " · continued from \(resumed) already received"
                }
                notify(id: transfer.id.uuidString,
                       title: "Received \(transfer.summary) from \(transfer.deviceName)",
                       body: body, category: nil, transfer: transfer)
            }
        case .failed(let reason):
            var body = reason
            let saved = transfer.savedFiles.count
            if transfer.files.count > 1 {
                body += ". \(saved) of \(transfer.files.count) files were saved."
            }
            body += " Send again from the phone to retry."
            notify(id: transfer.id.uuidString,
                   title: "Transfer from \(transfer.deviceName) was interrupted",
                   body: body, category: nil, transfer: transfer)
        case .cancelled(let bySender) where bySender && transfer.bytesReceived > 0:
            notify(id: transfer.id.uuidString,
                   title: "\(transfer.deviceName) cancelled the transfer",
                   body: transfer.summary, category: nil, transfer: transfer)
        default:
            break
        }
    }

    func refreshNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            DispatchQueue.main.async { self.notificationsAllowed = allowed }
        }
    }

    func openNotificationSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=app.qshare.mac")!
        NSWorkspace.shared.open(url)
    }

    private func dismissLater(_ transfer: IncomingTransfer, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            if self.panelHovered {
                self.dismissLater(transfer, after: 3)
            } else {
                self.dismissFromPanel(transfer)
            }
        }
    }

    func dismissFromPanel(_ transfer: IncomingTransfer) {
        guard panelTransfers.contains(where: { $0.id == transfer.id }) else { return }
        panelTransfers.removeAll { $0.id == transfer.id }
        panel.refresh()
    }

    // MARK: - Notifications

    private func setUpNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let accept = UNNotificationAction(identifier: Action.accept, title: "Accept")
        let decline = UNNotificationAction(identifier: Action.decline, title: "Decline", options: [.destructive])
        let openLink = UNNotificationAction(identifier: Action.openLink, title: "Open Link", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Action.requestCategory, actions: [accept, decline], intentIdentifiers: []),
            UNNotificationCategory(identifier: Action.linkCategory, actions: [openLink], intentIdentifiers: []),
        ])
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] _, error in
            if let error { NSLog("QShare notification authorization error: %@", String(describing: error)) }
            self?.refreshNotificationStatus()
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refreshNotificationStatus() }
    }

    private func requestID(_ transfer: IncomingTransfer) -> String { "request-\(transfer.id.uuidString)" }

    private func notifyRequest(_ transfer: IncomingTransfer) {
        var body = transfer.summary
        if transfer.totalBytes > 0 {
            body += " (\(ByteCountFormatter.string(fromByteCount: transfer.totalBytes, countStyle: .file)))"
        }
        body += " · PIN \(transfer.pin)"
        notify(id: requestID(transfer), title: "\(transfer.deviceName) wants to send you something",
               body: body, category: Action.requestCategory, transfer: transfer)
    }

    private func notify(id: String, title: String, body: String, category: String?, transfer: IncomingTransfer) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["transfer": transfer.id.uuidString]
        if let category { content.categoryIdentifier = category }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let id = response.notification.request.content.userInfo["transfer"] as? String
        let action = response.actionIdentifier
        DispatchQueue.main.async {
            defer { completionHandler() }
            guard let transfer = self.receiver.transfers.first(where: { $0.id.uuidString == id }) else { return }
            switch action {
            case Action.accept:
                transfer.accept()
            case Action.decline:
                transfer.decline()
            case Action.openLink:
                if let url = self.link(in: transfer) { NSWorkspace.shared.open(url) }
            case UNNotificationDefaultActionIdentifier:
                if transfer.state == .completed, !transfer.savedFiles.isEmpty { self.reveal(transfer) }
            default:
                break
            }
        }
    }
}
