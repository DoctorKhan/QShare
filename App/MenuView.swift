import QuickShareKit
import SwiftUI

struct MenuView: View {
    @ObservedObject var model: AppModel
    @State private var showingSettings = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if !model.notificationsAllowed {
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: "bell.slash")
                        .foregroundStyle(.orange)
                    Text("Notifications are off. Requests still pop up in a panel at the top right.")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button("Turn On…") { model.openNotificationSettings() }
                        .controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            Divider()
            if showingSettings {
                SettingsView(model: model)
            } else {
                transferList
            }
            Divider()
            footer
        }
        .frame(width: 360)
        .onAppear { model.refreshNotificationStatus() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .font(.headline)
                Text(statusDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button {
                showingSettings.toggle()
            } label: {
                Image(systemName: showingSettings ? "xmark.circle.fill" : "gearshape")
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(showingSettings ? "Close settings" : "Settings")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var statusColor: Color {
        switch model.receiver.status {
        case .ready: return .green
        case .starting: return .yellow
        case .unavailable: return .orange
        case .stopped: return .gray
        }
    }

    private var statusTitle: String {
        switch model.receiver.status {
        case .ready: return "Ready to receive"
        case .starting: return "Starting…"
        case .unavailable: return "Reconnecting…"
        case .stopped: return "Stopped"
        }
    }

    private var statusDetail: String {
        switch model.receiver.status {
        case .ready:
            if model.receiver.senderNearby, model.pendingCount == 0, !model.isReceiving {
                return "A nearby phone is sharing. Pick “\(model.deviceName)” on it."
            }
            return "Visible as “\(model.deviceName)” on this network"
        case .starting:
            return "Setting up the connection"
        case .unavailable(let reason):
            return reason
        case .stopped:
            return "Not visible to other devices"
        }
    }

    // MARK: - Transfers

    @ViewBuilder
    private var transferList: some View {
        if model.receiver.transfers.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("Nothing received yet")
                    .font(.callout.weight(.medium))
                Text("On your phone, tap Share, then Quick Share, and choose “\(model.deviceName)”. Both devices need to be on the same Wi-Fi network.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 28)
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(model.receiver.transfers) { transfer in
                        TransferRow(transfer: transfer, model: model)
                        if transfer.id != model.receiver.transfers.last?.id {
                            Divider().padding(.leading, 48)
                        }
                    }
                }
            }
            .frame(maxHeight: 380)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 14) {
            Button("Open \(model.destination.lastPathComponent)") {
                NSWorkspace.shared.open(model.destination)
            }
            if model.receiver.transfers.contains(where: { $0.state.isFinished }) {
                Button("Clear") { model.receiver.clearFinished() }
            }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
        }
        .buttonStyle(.plain)
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

// MARK: - Row

struct TransferRow: View {
    @ObservedObject var transfer: IncomingTransfer
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(iconColor)
                .frame(width: 24)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                Text(transfer.summary)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                detail
            }
            Spacer(minLength: 4)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            if transfer.state == .completed { model.open(transfer) }
        }
    }

    private var icon: String {
        switch transfer.state {
        case .awaitingApproval: return deviceIcon
        case .receiving: return "arrow.down.circle"
        case .completed: return transfer.files.isEmpty ? (transfer.textKind == .url ? "link" : "text.quote") : "checkmark.circle.fill"
        case .declined, .cancelled: return "xmark.circle"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var deviceIcon: String {
        switch transfer.deviceType {
        case .tablet: return "ipad"
        case .laptop: return "laptopcomputer"
        default: return "smartphone"
        }
    }

    private var iconColor: Color {
        switch transfer.state {
        case .completed: return transfer.files.isEmpty ? .accentColor : .green
        case .failed: return .orange
        case .declined, .cancelled: return .secondary
        default: return .accentColor
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch transfer.state {
        case .awaitingApproval:
            Text("\(transfer.deviceName) wants to send this\(sizeSuffix)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("PIN \(transfer.pin)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .help("This should match the PIN shown on the phone")
            HStack(spacing: 8) {
                Button("Accept") { transfer.accept() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                Button("Decline") { transfer.decline() }
                Menu {
                    Button("Accept and always accept from “\(transfer.deviceName)”") {
                        model.trust(transfer.deviceName)
                        transfer.accept()
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .controlSize(.small)
            .padding(.top, 2)

        case .receiving:
            ProgressView(value: transfer.fractionCompleted)
                .progressViewStyle(.linear)
            Text(progressText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(2)

        case .completed:
            if let text = transfer.text, transfer.files.isEmpty {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            Text(completedText)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                if transfer.files.isEmpty {
                    if model.link(in: transfer) != nil {
                        Button("Open Link") { model.open(transfer) }
                            .buttonStyle(.borderedProminent)
                    }
                    Button("Copy") { model.copyText(transfer) }
                } else {
                    Button("Show in Finder") { model.reveal(transfer) }
                        .buttonStyle(.borderedProminent)
                    if transfer.savedFiles.count == 1 {
                        Button("Open") { model.open(transfer) }
                    }
                }
            }
            .controlSize(.small)
            .padding(.top, 2)

        case .declined:
            Text("Declined · \(transfer.deviceName)")
                .font(.caption)
                .foregroundStyle(.secondary)

        case .cancelled(let bySender):
            Text(bySender ? "Cancelled on \(transfer.deviceName)" : "Cancelled")
                .font(.caption)
                .foregroundStyle(.secondary)

        case .failed(let reason):
            Text(failedText(reason))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch transfer.state {
        case .receiving:
            Button {
                transfer.cancel()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Cancel")
        case .failed where !transfer.savedFiles.isEmpty:
            iconButton("magnifyingglass", help: "Show saved files in Finder") { model.reveal(transfer) }
        default:
            EmptyView()
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }

    private var sizeSuffix: String {
        transfer.totalBytes > 0 ? " (\(format(transfer.totalBytes)))" : ""
    }

    private var progressText: String {
        var parts = ["\(format(transfer.bytesReceived)) of \(format(transfer.totalBytes))"]
        if transfer.bytesPerSecond > 1 {
            parts.append("\(format(Int64(transfer.bytesPerSecond)))/s")
            let remaining = Double(transfer.totalBytes - transfer.bytesReceived) / transfer.bytesPerSecond
            if remaining.isFinite, remaining >= 1 { parts.append(duration(remaining)) }
        }
        if transfer.resumedBytes > 0 {
            parts.append("continued from \(format(transfer.resumedBytes))")
        }
        return parts.joined(separator: " · ")
    }

    private var completedText: String {
        var parts = [transfer.deviceName]
        if transfer.totalBytes > 0 { parts.append(format(transfer.totalBytes)) }
        if transfer.files.isEmpty { parts.append("copied to clipboard") }
        if let finished = transfer.finishedAt {
            parts.append(finished.formatted(date: .omitted, time: .shortened))
        }
        return parts.joined(separator: " · ")
    }

    private func failedText(_ reason: String) -> String {
        var text = reason
        if transfer.files.count > 1 {
            text += ". \(transfer.savedFiles.count) of \(transfer.files.count) files saved"
        }
        return text + ". Send again from the phone to retry."
    }

    private func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func duration(_ seconds: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : seconds >= 60 ? [.minute, .second] : [.second]
        return (formatter.string(from: seconds) ?? "") + " left"
    }
}
