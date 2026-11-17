import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var nameDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            field("Name shown on other devices") {
                TextField("Mac", text: $nameDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(commitName)
            }

            field("Save received files to") {
                HStack {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    Text(model.destination.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer()
                    Button("Change…") { model.chooseDestination() }
                        .controlSize(.small)
                }
            }

            field("Accept automatically") {
                Picker("", selection: $model.autoAccept) {
                    ForEach(AutoAcceptMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                if model.autoAccept != .ask {
                    Text("Devices are recognised by name only, which another device on your network could imitate. Use this on networks you trust.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.autoAccept == .trusted {
                    if model.trustedDevices.isEmpty {
                        Text("No trusted devices yet. Choose “always accept” from the ••• menu on a request to add one.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(model.trustedDevices, id: \.self) { device in
                        HStack {
                            Image(systemName: "smartphone")
                                .foregroundStyle(.secondary)
                            Text(device)
                            Spacer()
                            Button("Remove") { model.untrust(device) }
                                .controlSize(.small)
                        }
                        .font(.callout)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Continue interrupted transfers", isOn: $model.resumeEnabled)
                Text("Keeps the part of a file that arrived before a connection dropped, and offers it to the phone when you send again. Phones that don't support this start the file over.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Show in Finder automatically after receiving", isOn: $model.revealAfterReceiving)
                    .padding(.top, 4)
                Toggle("Open at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }))
                    .padding(.top, 4)
                if let error = model.launchAtLoginError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .onAppear { nameDraft = model.deviceName }
        .onDisappear(perform: commitName)
    }

    private func commitName() {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != model.deviceName {
            model.deviceName = trimmed
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            content()
        }
    }
}
